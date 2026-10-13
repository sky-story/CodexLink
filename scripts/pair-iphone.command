#!/bin/zsh
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "${0:A:h}/.." || exit 1
node scripts/private-service.cjs pair
if [[ $? -ne 0 ]]; then
  read -r '?Press Return to close this window.'
fi
