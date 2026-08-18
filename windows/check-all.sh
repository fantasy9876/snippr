#!/bin/zsh
# Every project, every time — the RasterGate broke in CI because only the app
# and one gate were built locally before pushing.
#
# And NOT quiet: `-v quiet` swallowed a CS8524 the runner reported, so this
# script was reporting a clean build the compiler had already complained
# about. Warnings fail here for the same reason gates do.
set -e
cd "$(dirname "$0")/.."
log=$(mktemp)
for p in windows/Snippr.Win.csproj \
         windows/Snippr.Win.StitcherGate/Snippr.Win.StitcherGate.csproj \
         windows/Snippr.Win.ParityGate/Snippr.Win.ParityGate.csproj \
         windows/Snippr.Win.RasterGate/Snippr.Win.RasterGate.csproj; do
  echo "== $p"
  dotnet build "$p" -c Release --nologo | tee -a "$log"
done
if grep -qE ": (warning|error) [A-Z]+[0-9]+" "$log"; then
  echo "== build warnings/errors above — treat as failure"
  grep -E ": (warning|error) [A-Z]+[0-9]+" "$log" | sort -u
  rm -f "$log"
  exit 1
fi
rm -f "$log"
echo "== ParityGate (runs here; the raster half needs Windows)"
dotnet run --project windows/Snippr.Win.ParityGate/Snippr.Win.ParityGate.csproj \
  -c Release -f net10.0
