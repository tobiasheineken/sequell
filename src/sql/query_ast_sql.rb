require 'ostruct'

module Sql
  ##
  # Maintains a mapping of expressions to aliases for those expressions.
  # Any expression that
  class TermAliasMap < Hash
    def alias(expr)
      return expr.to_sql_output if expr.simple?
      expr_alias = self[expr.to_s]
      return expr_alias if expr_alias
      expr_alias = unique_alias(expr)
      expr.to_sql_output + " AS #{expr_alias}"
    end

    def unique_alias(expr)
      base = expr.to_s.gsub(/[^a-zA-Z]/, '_').gsub(/_+$/, '') + '_alias'
      known_aliases = Set.new(self.values)
      while  known_aliases.include?(base)
        base += "_0" unless base =~ /_\d+$/
        base = base.gsub(/(\d+)$/) { |m| ($1.to_i + 1).to_s }
      end
      self[expr.to_s] = base
      base
    end
  end

  class QueryASTSQL
    attr_reader :query_ast
    attr_reader :values

    def initialize(query_ast)
      @query_ast = query_ast
      @alias_map = TermAliasMap.new
      @values = []
    end

    def to_sql
      sql_query.sql
    end

    def sql_values
      sql_query.values
    end

  private

    def sql_query
      @sql_query ||= build_query
    end

    def option(key)
      query_ast.option(key)
    end

    def grouped?
      query_ast.summarise
    end

    def build_query
      sql = if subquery? && !exists_query? && !subquery_expression?
              "(#{query_sql}) AS #{query_alias}"
            else
              query_sql
            end
      # Building query also sets values
      OpenStruct.new(sql: sql, values: @values)
    end

    def query_sql
      query_ast.resolve_game_number!

      resolve(query_fields)
      load_values(query_fields)

      query_ast.autojoin_lookup_columns!
      load_values([query_ast.head])

      resolve([query_ast.summarise])
      load_values([query_ast.summarise])

      if query_ast.having
        resolve([query_ast.having])
        load_values([query_ast.having])
      end

      if query_ast.ordered?
        resolve(order_fields)
        load_values(order_fields)
      end

      ["SELECT #{query_columns.join(', ')}",
       "FROM #{query_tables_sql}",
       query_where_clause,
       query_group_by_clause,
       having_clause,
       query_order_by_clause,
       limit_clause].compact.join(' ')
    end

    def query_fields
      query_ast.select_expressions
    end

    def query_columns
      query_fields.map { |f|
        sql = f.to_sql_output
        f.alias && !f.alias.empty? ? "#{sql} AS #{f.alias}" : sql
      }
    end

    def query_tables_sql
      query_ast.to_table_list_sql
    end

    def query_where_clause
      conds = where_conditions
      return nil if conds.empty?
      "WHERE #{conds}"
    end

    def where_conditions
      query_ast.head.to_sql
    end

    def query_group_by_clause
      return unless grouped?
      "GROUP BY #{query_summary_sql_columns.join(', ')}"
    end

    def having_clause
      return unless grouped? && query_ast.having
      "HAVING #{query_ast.having.to_sql}"
    end

    def query_order_by_clause
      return if query_ast.simple_aggregate? || !order_fields || order_fields.empty?
      "ORDER BY " + order_fields.map(&:to_sql).join(', ')
    end

    def limit_clause
      # Limit clauses:
      # - Table queries (from:, tab:, join tables) have no limit unless asked for.
      # - Grouped queries have no limit unless asked for.
      # - All other queries have an implied limit and offset.
      # In all cases, the user can explicitly request an offset and a limit.
      # The offset is specified as a simple game number index. The limit
      # defaults to 1 if the offset is set, and can be changed via the -count:X
      # keyed option.

      index = query_game_number
      limit = query_limit
      return unless index || limit
      segs = []
      segs << "OFFSET #{index - 1}" if index && index > 1
      segs << "LIMIT #{limit}" if limit && limit > 0
      return if segs.empty?
      segs.join(' ')
    end

    def query_game_number
      query_ast.game_number if query_ast.game_number?
    end

    def query_limit
      count = query_count_limit()
      return count if count
      1 if query_ast.game_number?
    end

    def query_count_limit
      count_opt = query_ast.option(:count)
      return unless count_opt
      count = count_opt.option_arguments[0].to_i
      return unless count > 0
      count
    end

    def sorts
      @sorts ||= query_ast.sorts
    end

    def query_summary_sql_columns
      query_ast.summarise.arguments.map { |arg|
        if arg.simple?
          arg.to_sql_output
        else
          @alias_map.alias(arg)
        end
      }
    end

    ##
    # Converts expressions on fields that belong in lookup tables into the
    # fields in the lookup tables.
    def resolve(exprs)
      exprs.each { |e|
        if e
          e.each_field { |f|
            Sql::FieldResolver.resolve(query_ast, f)
          }
        end
      }
    end

    def load_values(exprs)
      exprs.each { |e|
        if e
          e.each_value { |v|
            @values << v.value unless v.null?
          }
        end
      }
    end

    def order_fields
      @order_fields ||= query_ast.order.to_a
    end

    def subquery?
      query_ast.subquery?
    end

    def exists_query?
      query_ast.exists_query?
    end

    def subquery_expression?
      query_ast.subquery_expression?
    end

    def query_alias
      query_ast.alias
    end
  end
end
