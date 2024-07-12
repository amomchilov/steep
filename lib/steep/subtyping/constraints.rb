module Steep
  module Subtyping
    class Constraints
      class UnsatisfiedInvariantError < StandardError
        attr_reader :constraints
        attr_reader :reason

        def initialize(reason:, constraints:)
          @reason = reason
          @constraints = constraints
          super "Invalid constraint: reason=#{reason.message}, constraints=#{constraints.to_s}"
        end

        class VariablesUnknownsNotDisjoint
          attr_reader :vars

          def initialize(vars:)
            @vars = vars
          end

          def message
            "Variables and unknowns should be disjoint (#{vars})"
          end
        end

        class VariablesFreeVariablesNotDisjoint
          attr_reader :var
          attr_reader :lower_bound
          attr_reader :upper_bound

          def initialize(var:, lower_bound:, upper_bound:)
            @var = var
            @lower_bound = lower_bound
            @upper_bound = upper_bound
          end

          def message
            "Variables and FV(constraints) should be disjoint (#{var}, #{lower_bound}, #{upper_bound})"
          end
        end

        class UnknownsFreeVariableNotDisjoint
          attr_reader :var
          attr_reader :upper_bound
          attr_reader :lower_bound

          def initialize(var:, lower_bound:, upper_bound:)
            @var = var
            @lower_bound = lower_bound
            @upper_bound = upper_bound
          end

          def message
            "Unknowns and FV(constraints) should be disjoint (#{var}, #{lower_bound}, #{upper_bound})"
          end
        end
      end

      class UnsatisfiableConstraint < StandardError
        attr_reader :var
        attr_reader :sub_type
        attr_reader :super_type
        attr_reader :result

        def initialize(var:, sub_type:, super_type:, result:)
          @var = var
          @sub_type = sub_type
          @super_type = super_type
          @result = result

          super "Unsatisfiable constraint on #{var}: #{sub_type} <: #{super_type}"
        end
      end

      attr_reader :dictionary
      attr_reader :vars

      def initialize(unknowns:)
        @dictionary = {}
        @vars = Set.new

        unknowns.each do |var|
          dictionary[var] = [Set.new, Set.new]
        end
      end

      def self.empty
        new(unknowns: [])
      end

      def add_var(*vars)
        vars.each do |var|
          self.vars << var
        end

        unless Set.new(vars).disjoint?(unknowns)
          raise UnsatisfiedInvariantError.new(
            reason: UnsatisfiedInvariantError::VariablesUnknownsNotDisjoint.new(vars: vars),
            constraints: self
          )
        end
      end

      def add(var, sub_type: nil, super_type: nil, skip: false)
        subs, supers = dictionary[var]

        if sub_type.is_a?(AST::Types::Logic::Base)
          sub_type = AST::Builtin.bool_type
        end

        if super_type.is_a?(AST::Types::Logic::Base)
          super_type = AST::Builtin.bool_type
        end

        if super_type && !super_type.is_a?(AST::Types::Top)
          type = eliminate_variable(super_type, to: AST::Types::Top.new)
          supers << type
        end

        if sub_type && !sub_type.is_a?(AST::Types::Bot)
          type = eliminate_variable(sub_type, to: AST::Types::Bot.new)
          subs << type
        end

        super_fvs = supers.each_with_object(Set.new) do |type, fvs|
          fvs.merge(type.free_variables)
        end
        sub_fvs = subs.each_with_object(Set.new) do |type, fvs|
          fvs.merge(type.free_variables)
        end

        unless super_fvs.disjoint?(unknowns) || sub_fvs.disjoint?(unknowns)
          raise UnsatisfiedInvariantError.new(
            reason: UnsatisfiedInvariantError::UnknownsFreeVariableNotDisjoint.new(
              var: var,
              lower_bound: sub_type,
              upper_bound: super_type
            ),
            constraints: self
          )
        end
      end

      def eliminate_variable(type, to:)
        case type
        when AST::Types::Name::Instance, AST::Types::Name::Alias, AST::Types::Name::Interface
          type.args.map do |ty|
            eliminate_variable(ty, to: AST::Types::Any.new)
          end.yield_self do |args|
            type.class.new(name: type.name, args: args, location: type.location)
          end
        when AST::Types::Union
          type.types.map do |ty|
            eliminate_variable(ty, to: AST::Types::Any.new)
          end.yield_self do |types|
            AST::Types::Union.build(types: types)
          end
        when AST::Types::Intersection
          type.types.map do |ty|
            eliminate_variable(ty, to: AST::Types::Any.new)
          end.yield_self do |types|
            AST::Types::Intersection.build(types: types)
          end
        when AST::Types::Var
          if vars.member?(type.name)
            to
          else
            type
          end
        when AST::Types::Tuple
          AST::Types::Tuple.new(
            types: type.types.map {|ty| eliminate_variable(ty, to: AST::Builtin.any_type) },
            location: type.location
          )
        when AST::Types::Record
          AST::Types::Record.new(
            elements: type.elements.transform_values {|ty| eliminate_variable(ty, to: AST::Builtin.any_type) },
            location: type.location
          )
        when AST::Types::Proc
          type.map_type {|ty| eliminate_variable(ty, to: AST::Builtin.any_type) }
        else
          type
        end
      end

      def unknown?(var)
        dictionary.key?(var)
      end

      def unknowns
        Set.new(dictionary.keys)
      end

      def unknown!(var)
        unless unknown?(var)
          dictionary[var] = [Set.new, Set.new, Set.new]
        end
      end

      def empty?
        dictionary.keys.empty?
      end

      def upper_bound(var)
        upper_bound = upper_bound_types(var)

        case upper_bound.size
        when 0
          AST::Types::Top.new
        when 1
          upper_bound.first || raise
        else
          AST::Types::Intersection.build(types: upper_bound.to_a)
        end
      end

      def lower_bound(var)
        lower_bound = lower_bound_types(var)

        case lower_bound.size
        when 0
          AST::Types::Bot.new
        when 1
          lower_bound.first || raise
        else
          AST::Types::Union.build(types: lower_bound.to_a)
        end
      end

      Context = _ = Struct.new(:variance, :self_type, :instance_type, :class_type, keyword_init: true)

      def self.solve(constraints, checker, context)
        subst = Interface::Substitution.empty

        double_end_constraints = [] #: Array[Symbol]
        no_constraints = [] #: Array[Symbol]

        constraints.dictionary.each_key do |var|
          constraint = constraints.constraint(var)

          case constraint
          when Array
            double_end_constraints << var
          when nil
            no_constraints << var
          else
            type = constraint.subst(subst)
            subst.add!(var, type)
          end
        end

        if double_end_constraints.empty?
          untyped_subst = Interface::Substitution.build(no_constraints, no_constraints.map { AST::Types::Any.new})
          return subst.merge!(untyped_subst)
        end

        additional_relations = {} #: Hash[Symbol, Relation[AST::Types::t]]
        double_end_constraints.each do |var|
          additional_relations[var] = Relation.new(
            sub_type: constraints.lower_bound(var).subst(subst),
            super_type: constraints.upper_bound(var).subst(subst)
          )
        end

        fvs = additional_relations.each_with_object(Set.new) do |(var, relation), fvs| #$ Set[Symbol]
          relation.sub_type.free_variables.each do |fv|
            fvs << fv if fv.is_a?(Symbol)
          end
          relation.super_type.free_variables.each do |fv|
            fvs << fv if fv.is_a?(Symbol)
          end
        end

        fvs = fvs & no_constraints

        cs = Constraints.new(unknowns: fvs)
        additional_relations.each do |var, relation|
          checker.check(relation, self_type: context.self_type, instance_type: context.instance_type, class_type: context.class_type, constraints: cs).yield_self do |result|
            unless result.success?
              return UnsatisfiableConstraint.new(
                var: var,
                sub_type: result.relation.sub_type,
                super_type: result.relation.super_type,
                result: result
              )
            end
          end
        end

        solution = solve(cs, checker, context)
        if solution.is_a?(Interface::Substitution)
          subst.merge!(solution)

          additional_relations.each do |var, relation|
            type =
              case
              when context.variance.contravariant?(var)
                relation.super_type
              when context.variance.covariant?(var)
                relation.sub_type
              else
                if relation.sub_type.level.join > relation.super_type.level.join
                  relation.super_type
                else
                  relation.sub_type
                end
              end

            subst.add!(var, type.subst(solution))
          end

          subst
        else
          solution
        end
      end

      def has_constraint?(var)
        constraint(var) ? true : false
      end

      def each
        if block_given?
          dictionary.each_key do |var|
            yield [var, lower_bound(var), upper_bound(var)]
          end
        else
          enum_for :each
        end
      end

      def to_s
        strings = each.map do |var, lower_bound, upper_bound|
          "#{lower_bound} <: #{var} <: #{upper_bound}"
        end

        "#{unknowns.to_a.join(",")}/#{vars.to_a.join(",")} |- { #{strings.join(", ")} }"
      end

      def constraint(var_name)
        upper_bound = upper_bound(var_name)
        lower_bound = lower_bound(var_name)

        case
        when upper_bound.is_a?(AST::Types::Top) && lower_bound.is_a?(AST::Types::Bot)
          nil
        when upper_bound.is_a?(AST::Types::Top)
          lower_bound
        when lower_bound.is_a?(AST::Types::Bot)
          upper_bound
        else
          [lower_bound, upper_bound]
        end
      end

      def lower_bound_types(var_name)
        lower, _, _ = dictionary[var_name]
        lower
      end

      def upper_bound_types(var_name)
        _, upper = dictionary[var_name]
        upper
      end
    end
  end
end
