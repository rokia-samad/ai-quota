#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
developer_dir="$(xcode-select -p)"
# Some CLT distributions ship Testing outside SwiftPM's default search paths.
if [[ "$developer_dir" == */CommandLineTools && -d "$developer_dir/Library/Developer/Frameworks/Testing.framework" ]]; then
  swift test -Xswiftc -F -Xswiftc "$developer_dir/Library/Developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib" "$@"
else
  swift test "$@"
fi
