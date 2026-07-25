@echo off
set GOOS=windows
set GOARCH=amd64
set CC=x86_64-w64-mingw32-gcc
set CGO_ENABLED=1
del bin\hiddify-core.dll bin\KuaifeiCli.exe bin\HiddifyCli.exe
set CGO_LDFLAGS=
go build -trimpath -tags with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc -ldflags="-w -s" -buildmode=c-shared -o bin/hiddify-core.dll ./platform/desktop
if errorlevel 1 exit /b %errorlevel%
rsrc -ico .\assets\hiddify-cli.ico -o cmd\bydll\cli.syso
if errorlevel 1 exit /b %errorlevel%

copy bin\hiddify-core.dll .
set CGO_LDFLAGS="hiddify-core.dll"
go build -o bin/KuaifeiCli.exe ./cmd/bydll/
if errorlevel 1 exit /b %errorlevel%
del hiddify-core.dll
