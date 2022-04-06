# frozen_string_literal: true

module RubyLsp
  module Requests
    class FoldingRanges < Visitor
      SIMPLE_FOLDABLES = [
        SyntaxTree::Args,
        SyntaxTree::BraceBlock,
        SyntaxTree::Case,
        SyntaxTree::ClassDeclaration,
        SyntaxTree::DoBlock,
        SyntaxTree::For,
        SyntaxTree::HashLiteral,
        SyntaxTree::Heredoc,
        SyntaxTree::If,
        SyntaxTree::ModuleDeclaration,
        SyntaxTree::SClass,
        SyntaxTree::Unless,
        SyntaxTree::Until,
        SyntaxTree::While,
      ].freeze

      NODES_WITH_STATEMENTS = [
        SyntaxTree::Else,
        SyntaxTree::Elsif,
        SyntaxTree::Ensure,
        SyntaxTree::In,
        SyntaxTree::Rescue,
        SyntaxTree::When,
      ].freeze

      def self.run(parsed_tree)
        new(parsed_tree).run
      end

      def initialize(parsed_tree)
        @parsed_tree = parsed_tree
        @ranges = []
        @partial_range = nil

        super()
      end

      def run
        visit(@parsed_tree.tree)
        emit_partial_range
        @ranges
      end

      private

      def visit(node)
        return unless handle_partial_range(node)

        case node
        when *SIMPLE_FOLDABLES
          add_node_range(node)
        when *NODES_WITH_STATEMENTS
          add_lines_range(node.location.start_line, node.statements.location.end_line) unless node.statements.empty?
        when SyntaxTree::Def, SyntaxTree::Defs
          add_def_range(node)
          return
        end

        super
      end

      def visit_arg_paren(node)
        add_node_range(node)

        visit_all(node.arguments.parts) if node.arguments
      end

      def visit_array_literal(node)
        add_node_range(node)

        visit_all(node.contents.parts) if node.contents
      end

      def visit_begin(node)
        unless node.bodystmt.statements.empty?
          add_lines_range(node.location.start_line, node.bodystmt.statements.location.end_line)
        end

        super
      end

      def visit_call(node)
        receiver = node.receiver
        loop do
          case receiver
          when SyntaxTree::Call
            visit(receiver.arguments)
            receiver = receiver.receiver
          when SyntaxTree::MethodAddBlock
            visit(receiver.block)
            receiver = receiver.call.receiver
          else
            break
          end
        end

        add_lines_range(receiver.location.start_line, node.location.end_line)

        parts = node.arguments&.arguments&.parts
        visit_all(parts) unless parts.nil? || parts.empty?
      end

      def visit_string_concat(node)
        end_line = node.right.location.end_line
        left = node.left

        left = left.left while left.is_a?(SyntaxTree::StringConcat)
        start_line = left.location.start_line

        add_lines_range(start_line, end_line)
      end

      class PartialRange
        attr_reader :kind, :end_line

        def self.from(node, kind)
          new(node.location.start_line - 1, node.location.end_line - 1, kind)
        end

        def initialize(start_line, end_line, kind)
          @start_line = start_line
          @end_line = end_line
          @kind = kind
        end

        def extend_to(node)
          @end_line = node.location.end_line - 1
          self
        end

        def new_section?(node)
          node.is_a?(SyntaxTree::Comment) && @end_line + 1 != node.location.start_line - 1
        end

        def to_range
          LanguageServer::Protocol::Interface::FoldingRange.new(
            start_line: @start_line,
            end_line: @end_line,
            kind: @kind
          )
        end
      end

      def handle_partial_range(node)
        kind = partial_range_kind(node)

        if kind.nil?
          emit_partial_range
          return true
        end

        @partial_range = if @partial_range.nil?
          PartialRange.from(node, kind)
        elsif @partial_range.kind != kind || @partial_range.new_section?(node)
          emit_partial_range
          PartialRange.from(node, kind)
        else
          @partial_range.extend_to(node)
        end

        false
      end

      def partial_range_kind(node)
        case node
        when SyntaxTree::Comment
          "comment"
        when SyntaxTree::Command
          if node.message.value == "require" || node.message.value == "require_relative"
            "imports"
          end
        end
      end

      def emit_partial_range
        return if @partial_range.nil?

        @ranges << @partial_range.to_range
        @partial_range = nil
      end

      def add_def_range(node)
        params_location = node.params.location

        if params_location.start_line < params_location.end_line
          add_lines_range(params_location.end_line, node.location.end_line)
        else
          add_node_range(node)
        end

        visit(node.bodystmt.statements)
      end

      def add_node_range(node)
        add_location_range(node.location)
      end

      def add_location_range(location)
        add_lines_range(location.start_line, location.end_line)
      end

      def add_lines_range(start_line, end_line)
        return if start_line >= end_line

        @ranges << LanguageServer::Protocol::Interface::FoldingRange.new(
          start_line: start_line - 1,
          end_line: end_line - 1,
          kind: "region"
        )
      end
    end
  end
end
