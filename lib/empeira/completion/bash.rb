# frozen_string_literal: true

require 'shellwords'

module Empeira
  module Completion
    module Bash
      module_function

      # COMP_WORDS retains shell quoting, including an unfinished quoted word.
      # Shellwords only parses text; it never evaluates substitutions or commands.
      def path_prefix(value)
        return value unless value.match?(/[\\'"]/)

        [value, "#{value}'", "#{value}\""].each do |candidate|
          words = Shellwords.split(candidate)
          return words.first if words.size == 1
        rescue ArgumentError
          next
        end
        value
      end

      def generate
        <<~'BASH'
          # Empeira Bash completion. Load with: source <(empeira completion bash)
          _empeira_complete() {
            local candidate mode='' prefix='' replacement='' phase=0
            COMPREPLY=()
            while IFS= read -r -d '' candidate; do
              if [[ "$candidate" == $'\x1f'file || "$candidate" == $'\x1f'directory ]]; then
                mode="${candidate:1}"
                phase=1
              elif [[ $phase == 1 ]]; then
                prefix="$candidate"
                phase=2
              elif [[ $phase == 2 ]]; then
                replacement="$candidate"
                phase=3
              else
                COMPREPLY+=("$candidate")
              fi
            done < <(printf '%s\0' "${COMP_WORDS[@]:1}" | "${COMP_WORDS[0]}" completion candidates "$COMP_CWORD" --null)
            if [[ -n "$mode" ]]; then
              compopt -o filenames 2>/dev/null || :
              while IFS= read -r -d '' candidate; do COMPREPLY+=("$replacement$candidate"); done < <(
                # Native pathname expansion with NUL framing also preserves newlines.
                # Shell settings change only in this subshell, including on Bash 3.2.
                shopt -s nullglob dotglob
                for candidate in "$prefix"*; do
                  [[ "$mode" == directory && ! -d "$candidate" ]] && continue
                  printf '%s\0' "$candidate"
                done
              )
            fi
          }
          complete -o filenames -F _empeira_complete empeira
        BASH
      end
    end
  end
end
