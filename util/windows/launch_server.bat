PATH=compiler/bin;%PATH%
"bin/buildat_server.exe" -S . -U Urho3D -i src/interface -r cache/rccpp_build -c "c++.exe -Lbin" -m games/minigame %*