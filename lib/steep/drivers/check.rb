module Steep
  module Drivers
    class Check
      LSP = LanguageServer::Protocol

      attr_reader :stdout
      attr_reader :stderr
      attr_reader :command_line_patterns
      attr_accessor :with_expectations_path
      attr_accessor :save_expectations_path

      include Utils::DriverHelper

      def initialize(stdout:, stderr:)
        @stdout = stdout
        @stderr = stderr
        @command_line_patterns = []
      end

      def run
        project = load_config()

        loader = Project::FileLoader.new(project: project)
        loader.load_sources(command_line_patterns)
        loader.load_signatures()

        stdout.puts Rainbow("# Type checking files:").bold
        stdout.puts

        client_read, server_write = IO.pipe
        server_read, client_write = IO.pipe

        client_reader = LanguageServer::Protocol::Transport::Io::Reader.new(client_read)
        client_writer = LanguageServer::Protocol::Transport::Io::Writer.new(client_write)

        server_reader = LanguageServer::Protocol::Transport::Io::Reader.new(server_read)
        server_writer = LanguageServer::Protocol::Transport::Io::Writer.new(server_write)

        interaction_worker = Server::WorkerProcess.spawn_worker(:interaction, name: "interaction", steepfile: project.steepfile_path, delay_shutdown: true)
        signature_worker = Server::WorkerProcess.spawn_worker(:signature, name: "signature", steepfile: project.steepfile_path, delay_shutdown: true)
        code_workers = Server::WorkerProcess.spawn_code_workers(steepfile: project.steepfile_path, delay_shutdown: true)

        master = Server::Master.new(
          project: project,
          reader: server_reader,
          writer: server_writer,
          interaction_worker: interaction_worker,
          signature_worker: signature_worker,
          code_workers: code_workers
        )

        main_thread = Thread.start do
          master.start()
        end
        main_thread.abort_on_exception = true

        client_writer.write({ method: :initialize, id: 0 })

        shutdown_id = -1
        client_writer.write({ method: :shutdown, id: shutdown_id })

        diagnostic_notifications = []
        error_messages = []
        client_reader.read do |response|
          case
          when response[:method] == "textDocument/publishDiagnostics"
            ds = response[:params][:diagnostics]
            if ds.empty?
              stdout.print "."
            else
              stdout.print "F"
            end
            diagnostic_notifications << response[:params]
            stdout.flush
          when response[:method] == "window/showMessage"
            # Assuming ERROR message means unrecoverable error.
            message = response[:params]
            if message[:type] == LSP::Constant::MessageType::ERROR
              error_messages << message[:message]
            end
          when response[:id] == shutdown_id
            break
          end
        end

        client_writer.write({ method: :exit })
        client_writer.io.close()

        main_thread.join()

        stdout.puts
        stdout.puts

        if error_messages.empty?
          case
          when with_expectations_path
            print_expectations(project: project,
                               expectations_path: with_expectations_path,
                               notifications: diagnostic_notifications)
          when save_expectations_path
            save_expectations(project: project,
                              expectations_path: save_expectations_path,
                              notifications: diagnostic_notifications)
          else
            print_result(project: project, notifications: diagnostic_notifications)
          end
        else
          stdout.puts Rainbow("Unexpected error reported. 🚨").red.bold
          1
        end
      end

      def print_expectations(project:, expectations_path:, notifications:)
        expectations = Expectations.load(path: expectations_path, content: expectations_path.read)

        expected_count = 0
        unexpected_count = 0
        missing_count = 0

        notifications.each do |notification|
          path = project.relative_path(Pathname(URI.parse(notification[:uri]).path))
          diagnostics = notification[:diagnostics]
          test = expectations.test(path: path, diagnostics: diagnostics)

          buffer = RBS::Buffer.new(name: path, content: path.read)
          printer = DiagnosticPrinter.new(buffer: buffer, stdout: stdout)

          test.each_diagnostics.each do |type, diag|
            case type
            when :expected
              expected_count += 1
            when :unexpected
              unexpected_count += 1
              printer.print(diag, prefix: Rainbow("+ ").green)
            when :missing
              missing_count += 1
              printer.print(diag, prefix: Rainbow("- ").red)
            end
          end
        end

        stdout.puts

        if unexpected_count > 0 || missing_count > 0
          stdout.puts Rainbow("Expectations unsatisfied:").bold.red
          stdout.puts "  #{expected_count} expected diagnostics"
          stdout.puts Rainbow("  + #{unexpected_count} unexpected diagnostics").green
          stdout.puts Rainbow("  - #{missing_count} missing diagnostics").red
          1
        else
          stdout.puts Rainbow("Expectations satisfied:").bold.green
          stdout.puts "  #{expected_count} expected diagnostics"
          0
        end
      end

      def save_expectations(project:, expectations_path:, notifications:)
        expectations = Expectations.empty()

        notifications.each do |notification|
          unless notification[:diagnostics].empty?
            path = project.relative_path(Pathname(URI.parse(notification[:uri]).path))
            diagnostics = notification[:diagnostics]
            expectations.diagnostics[path] = diagnostics
          end
        end

        stdout.puts Rainbow("Updating #{expectations_path}...").bold
        expectations_path.write(expectations.to_yaml)
        0
      end

      def print_result(project:, notifications:)
        if notifications.all? {|notification| notification[:diagnostics].empty? }
          emoji = %w(🫖 🫖 🫖 🫖 🫖 🫖 🫖 🫖 🍵 🧋 🧉).sample
          stdout.puts Rainbow("No type error detected. #{emoji}").green.bold
          0
        else
          errors = notifications.reject {|notification| notification[:diagnostics].empty? }
          total = errors.sum {|notification| notification[:diagnostics].size }
          stdout.puts Rainbow("Detected #{total} problems from #{errors.size} files").red.bold
          stdout.puts

          errors.each do |notification|
            path = project.relative_path(Pathname(URI.parse(notification[:uri]).path))
            buffer = RBS::Buffer.new(name: path, content: path.read)
            printer = DiagnosticPrinter.new(buffer: buffer, stdout: stdout)

            notification[:diagnostics].each do |diag|
              printer.print(diag)
              stdout.puts
            end
          end
          1
        end
      end
    end
  end
end
