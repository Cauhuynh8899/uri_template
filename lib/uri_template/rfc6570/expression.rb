# -*- encoding : utf-8 -*-
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the Affero GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#    (c) 2011 - 2012 by Hannes Georg
#

require 'uri_template/rfc6570'

class URITemplate::RFC6570

    # @private
  class Expression < Token

    include URITemplate::Expression

    attr_reader :variables

    def initialize(vars)
      @variable_specs = vars
      @variables = vars.map(&:first)
      @variables.uniq!
    end

    PREFIX = ''.freeze
    SEPARATOR = ','.freeze
    PAIR_CONNECTOR = '='.freeze
    PAIR_IF_EMPTY = true
    LIST_CONNECTOR = ','.freeze
    BASE_LEVEL = 1

    CHARACTER_CLASS = CHARACTER_CLASSES[:unreserved]

    NAMED = false
    OPERATOR = ''

    def level
      if @variable_specs.none?{|_,expand,ml| expand || (ml > 0) }
        if @variable_specs.size == 1
          return self.class::BASE_LEVEL
        else
          return 3
        end
      else
        return 4
      end
    end

    def expands?
      @variable_specs.any?{|_,expand,_| expand }
    end

    def arity
      @variable_specs.size
    end

    def expand( vars )
      result = []
      @variable_specs.each{| var, expand , max_length |
        unless vars[var].nil?
          if max_length && max_length > 0 && ( vars[var].kind_of?(Array) || vars[var].kind_of?(Hash) )
            raise InvalidValue::LengthLimitInapplicable.new(var,vars[var])
          end
          if vars[var].kind_of?(Hash) or Utils.pair_array?(vars[var])
            result.push( *transform_hash(var, vars[var], expand, max_length) )
          elsif vars[var].kind_of? Array
            result.push( *transform_array(var, vars[var], expand, max_length) )
          else
            result.push( self_pair(var, vars[var], max_length) )
          end
        end
      }
      if result.any?
        return (self.class::PREFIX + result.join(self.class::SEPARATOR))
      else
        return ''
      end
    end

    def to_s
      return '{' + self.class::OPERATOR + @variable_specs.map{|name,expand,max_length| name + (expand ? '*': '') + (max_length > 0 ? (':' + max_length.to_s) : '') }.join(',') + '}'
    end

    def extract(position,matched)
      name, expand, max_length = @variable_specs[position]
      if matched.nil?
        return [[ name , matched ]]
      end
      if expand
        #TODO: do we really need this? - this could be stolen from rack
        ex = self.class.hash_extractor(max_length)
        rest = matched
        splitted = []
        if self.class::NAMED
          # 1 = name
          # 2 = value
          # 3 = rest
          until rest.size == 0
            match = ex.match(rest)
            if match.nil?
              raise "Couldn't match #{rest.inspect} againts the hash extractor. This is definitly a Bug. Please report this ASAP!"
            end
            if match.post_match.size == 0
              rest = match[3].to_s
            else
              rest = ''
            end
            splitted << [ decode(match[1]), decode(match[2] + rest , false) ]
            rest = match.post_match
          end
          result = Utils.pair_array_to_hash2( splitted )
          if result.size == 1 && result[0][0] == name
            return result
          else
            return [ [ name , result ] ]
          end
        else
          found_value = false
          # 1 = name and seperator
          # 2 = value
          # 3 = rest
          until rest.size == 0
            match = ex.match(rest)
            if match.nil?
              raise "Couldn't match #{rest.inspect} againts the hash extractor. This is definitly a Bug. Please report this ASAP!"
            end
            if match.post_match.size == 0
              rest = match[3].to_s
            else
              rest = ''
            end
            if match[1]
              found_value = true
              splitted << [ decode(match[1][0..-2]), decode(match[2] + rest , false) ]
            else
              splitted << [ decode(match[2] + rest), nil ]
            end
            rest = match.post_match
          end
          if !found_value
            return [ [ name, splitted.map{|n,v| decode(n , false) } ] ]
          else
            return [ [ name, splitted ] ]
          end
        end
      elsif self.class::NAMED
        return [ [ name, decode( matched[1..-1] ) ] ]
      end

      return [ [ name,  decode( matched ) ] ]
    end

  protected

    module ClassMethods

      def hash_extractor(max_length)
        @hash_extractors ||= {}
        @hash_extractors[max_length] ||= generate_hash_extractor(max_length)
      end

      def generate_hash_extractor(max_length)
        source = regex_builder
        source.push('\\A')
        source.escaped_separator.length('?')
        yield source
        source.capture do
          source.character_class(max_length).reluctant
        end
        source.group do
          source.push '\\z'
          source.push '|'
          source.escaped_separator
          source.negative_lookahead do
            source.escaped_separator
          end
        end
        return Regexp.new( source.join , Utils::KCODE_UTF8)
      end

      def regex_builder
        RegexBuilder.new(self)
      end

    end

    extend ClassMethods

    def escape(x)
      Utils.escape_url(Utils.object_to_param(x))
    end

    def unescape(x)
      Utils.unescape_url(x)
    end

    def regex_builder
      self.class.regex_builder
    end

    SPLITTER = /^(?:,(,*)|([^,]+))/

    def decode(x, split = true)
      if x.nil?
        if self.class::PAIR_IF_EMPTY
          return x
        else
          return ''
        end
      elsif split
        result = []
        URITemplate::RegexpEnumerator.new(SPLITTER).each(x) do |match|
          if match[1] and match[1].size > 0
            if match.post_match.size == 0
              result << match[1]
            else
              result << match[1][0..-2]
            end
          elsif match[2]
            result << unescape(match[2])
          end
        end
        case(result.size)
          when 0 then ''
          when 1 then result.first
          else result
        end
      else
        unescape(x)
      end
    end

    def cut(str,chars)
      if chars > 0
        md = Regexp.compile("\\A#{self.class::CHARACTER_CLASS[:class]}{0,#{chars.to_s}}", Utils::KCODE_UTF8).match(str)
        return md[0]
      else
        return str
      end
    end

    def pair(key, value, max_length = 0, &block)
      ek = key
      if block
        ev = value.map(&block).join(self.class::LIST_CONNECTOR) 
      else
        ev = escape(value)
      end
      if !self.class::PAIR_IF_EMPTY and ev.size == 0
        return ek
      else
        return ek + self.class::PAIR_CONNECTOR + cut( ev, max_length )
      end
    end

    def transform_hash(name, hsh, expand , max_length)
      if expand
        hsh.map{|key,value| pair(escape(key),value) }
      elsif hsh.none? && !self.class::NAMED
        []
      else
        [ self_pair(name,hsh){|key,value| escape(key)+self.class::LIST_CONNECTOR+escape(value)} ]
      end
    end

    def transform_array(name, ary, expand , max_length)
      if expand
        ary.map{|value| self_pair(name,value) }
      elsif ary.none? && !self.class::NAMED
        []
      else
        [ self_pair(name, ary){|value| escape(value) } ]
      end
    end
  end

  require 'uri_template/rfc6570/expression/named'
  require 'uri_template/rfc6570/expression/unnamed'

  class Expression::Basic < Expression::Unnamed
  end

  class Expression::Reserved < Expression::Unnamed

    CHARACTER_CLASS = CHARACTER_CLASSES[:unreserved_reserved_pct]
    OPERATOR = '+'.freeze
    BASE_LEVEL = 2

    def escape(x)
      Utils.escape_uri(Utils.object_to_param(x))
    end

    def unescape(x)
      Utils.unescape_uri(x)
    end

    def scheme?
      true
    end

    def host?
      true
    end

  end

  class Expression::Fragment < Expression::Unnamed

    CHARACTER_CLASS = CHARACTER_CLASSES[:unreserved_reserved_pct]
    PREFIX = '#'.freeze
    OPERATOR = '#'.freeze
    BASE_LEVEL = 2

    def escape(x)
      Utils.escape_uri(Utils.object_to_param(x))
    end

    def unescape(x)
      Utils.unescape_uri(x)
    end

  end

  class Expression::Label < Expression::Unnamed

    SEPARATOR = '.'.freeze
    PREFIX = '.'.freeze
    OPERATOR = '.'.freeze
    BASE_LEVEL = 3

  end

  class Expression::Path < Expression::Unnamed

    SEPARATOR = '/'.freeze
    PREFIX = '/'.freeze
    OPERATOR = '/'.freeze
    BASE_LEVEL = 3

    def starts_with_slash?
      true
    end

  end

  class Expression::PathParameters < Expression::Named

    SEPARATOR = ';'.freeze
    PREFIX = ';'.freeze
    NAMED = true
    PAIR_IF_EMPTY = false
    OPERATOR = ';'.freeze
    BASE_LEVEL = 3

  end

  class Expression::FormQuery < Expression::Named

    SEPARATOR = '&'.freeze
    PREFIX = '?'.freeze
    NAMED = true
    OPERATOR = '?'.freeze
    BASE_LEVEL = 3

  end

  class Expression::FormQueryContinuation < Expression::Named

    SEPARATOR = '&'.freeze
    PREFIX = '&'.freeze
    NAMED = true
    OPERATOR = '&'.freeze
    BASE_LEVEL = 3

  end

  # @private
  OPERATORS = {
    ''  => Expression::Basic,
    '+' => Expression::Reserved,
    '#' => Expression::Fragment,
    '.' => Expression::Label,
    '/' => Expression::Path,
    ';' => Expression::PathParameters,
    '?' => Expression::FormQuery,
    '&' => Expression::FormQueryContinuation
  }

end