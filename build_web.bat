@echo off

:: Point this to where you installed emscripten.
set EMSCRIPTEN_SDK_DIR=C:\Users\FColor04\scoop\apps\emscripten\current
set OUT_DIR=build\web

if not exist %OUT_DIR% mkdir %OUT_DIR%

set EMSDK_QUIET=1
call %EMSCRIPTEN_SDK_DIR%\emsdk_env.bat

:: Note RAYLIB_WASM_LIB=env.o -- env.o is an internal WASM object file. You can
:: see how RAYLIB_WASM_LIB is used inside <odin>/vendor/raylib/raylib.odin.
::
:: The emcc call will be fed the actual raylib library file. That stuff will end
:: up in env.o
::
:: Note that there is a rayGUI equivalent: -define:RAYGUI_WASM_LIB=env.o
odin build src -target:js_wasm32 -build-mode:obj -out:%OUT_DIR%\game.wasm.o -define:SDL3_WASM_LIB=env.o
IF %ERRORLEVEL% NEQ 0 exit /b 1

for /f "delims=" %%i in ('odin root') do set "ODIN_PATH=%%i"

copy "%ODIN_PATH%\core\sys\wasm\js\odin.js" %OUT_DIR%

set files=%OUT_DIR%\game.wasm.o "%ODIN_PATH%\vendor\sdl3\wasm\libSDL3.a" "%ODIN_PATH%\vendor\sdl3\wasm\libSDL_uclibc.a"

:: index_template.html contains the javascript code that calls the procedures in
:: source/main_web/main_web.odin
set flags=-sWASM_BIGINT -sWARN_ON_UNDEFINED_SYMBOLS=0 -sASSERTIONS --shell-file web\index_template.html --preload-file shaders

:: For debugging: Add `-g` to `emcc` (gives better error callstack in chrome)
::
:: This uses `cmd /c` to avoid emcc stealing the whole command prompt. Otherwise
:: it does not run the lines that follow it.
cmd /c emcc -g -o %OUT_DIR%\index.html %files% %flags%

del %OUT_DIR%\game.wasm.o 

echo Web build created in %OUT_DIR%
copy %OUT_DIR% C:\Users\FColor04\scoop\apps\xampp\current\htdocs
