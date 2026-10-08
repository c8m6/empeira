# frozen_string_literal: true

module Empeira
  module Completion
    module Bash
      module_function

      def generate
        <<~'BASH'
          # Empeira Bash completion. Load with: source <(empeira completion bash)
          _empeira_complete() {
            local candidate
            COMPREPLY=()
            while IFS= read -r candidate; do
              COMPREPLY+=("$candidate")
            done < <(printf '%s\0' "${COMP_WORDS[@]:1}" | "${COMP_WORDS[0]}" completion candidates "$COMP_CWORD")
          }
          complete -F _empeira_complete empeira
        BASH
      end
    end
  end
end
