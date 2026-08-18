#!/bin/zsh
# Every project, every time — the RasterGate broke in CI because only the app
# and one gate were built locally before pushing.
set -e
cd "$(dirname "$0")/.."
for p in windows/Snippr.Win.csproj \
         windows/Snippr.Win.StitcherGate/Snippr.Win.StitcherGate.csproj \
         windows/Snippr.Win.ParityGate/Snippr.Win.ParityGate.csproj \
         windows/Snippr.Win.RasterGate/Snippr.Win.RasterGate.csproj; do
  echo "== $p"
  dotnet build "$p" -c Release --nologo -v quiet
done
echo "== ParityGate (runs here; the raster half needs Windows)"
dotnet run --project windows/Snippr.Win.ParityGate/Snippr.Win.ParityGate.csproj \
  -c Release -f net10.0 --no-build 2>/dev/null \
  || dotnet run --project windows/Snippr.Win.ParityGate/Snippr.Win.ParityGate.csproj -c Release -f net10.0
