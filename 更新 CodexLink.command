#!/bin/zsh
# Keep this launcher in the project. A Finder alias may point to it.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONUNBUFFERED=1
cd "${0:A:h}" || exit 1
/usr/bin/python3 scripts/install-iphone.py "$@"
install_result=$?
if [[ -t 0 ]]; then
  read -r '?按回车键关闭窗口。'
fi
exit "$install_result"
