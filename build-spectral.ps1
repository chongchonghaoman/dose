param([string]$ToolRoot=(Join-Path $PSScriptRoot '../spectral-tools'),[string]$EngineSource=(Join-Path $PSScriptRoot '../SpektraLab-port'))
$ErrorActionPreference='Stop'
$ToolRoot=(Resolve-Path $ToolRoot).Path
$EngineSource=(Resolve-Path $EngineSource).Path
$compiler=Join-Path $ToolRoot 'llvm-mingw-20261020-ucrt-x86_64/bin'
$env:PATH=$compiler+';'+$env:PATH
$cmake=Join-Path $ToolRoot 'python/cmake/data/bin/cmake.exe'
$build=Join-Path $EngineSource 'build/dose-windows'
& $cmake -S $EngineSource -B $build -G Ninja '-DCMAKE_BUILD_TYPE=Release' '-DCMAKE_C_COMPILER=x86_64-w64-mingw32-clang.exe' '-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-clang++.exe' "-DCMAKE_MAKE_PROGRAM=$ToolRoot/python/bin/ninja.exe" '-DCMAKE_EXE_LINKER_FLAGS=-static' '-DCMAKE_SHARED_LINKER_FLAGS=-static' -DSPEKTRALAB_BUILD_NATIVE_RAW=ON -DSPEKTRALAB_BUILD_HOST=ON -DSPEKTRALAB_BUILD_DESKTOP=OFF -DSPEKTRALAB_REQUIRE_VULKAN=ON -DSPEKTRALAB_STATIC_RUNTIME=ON -DBUILD_TESTING=ON "-DSPEKTRALAB_VULKAN_HEADERS=$ToolRoot/Vulkan-Headers/include" "-DSPEKTRALAB_GLSLANG=$ToolRoot/glslang/bin/glslang.exe" "-DSPEKTRALAB_LIBRAW_SOURCE=$ToolRoot/LibRaw-0.22.2"
if($LASTEXITCODE){throw 'CMake configure failed'}
& $cmake --build $build -j 8
if($LASTEXITCODE){throw 'Native build failed'}
& (Join-Path $ToolRoot 'python/cmake/data/bin/ctest.exe') --test-dir $build --output-on-failure --timeout 60
if($LASTEXITCODE){throw 'Native tests failed'}
$destination=Join-Path $PSScriptRoot 'native/spectral'
New-Item -ItemType Directory -Force $destination | Out-Null
Copy-Item (Join-Path $build 'engine/host/spektralab-host.exe') $destination -Force
New-Item -ItemType Directory -Force (Join-Path $destination 'engine') | Out-Null
Copy-Item (Join-Path $build 'engine/resources/*') (Join-Path $destination 'engine') -Recurse -Force
# Same product-profile overlay as upstream engine/build.sh bundle. Keep the
# spektrafilm base resources untouched, including its neutral-filter table.
Copy-Item (Join-Path $EngineSource 'engine/resources_product/profiles/*.json') (Join-Path $destination 'engine/profiles') -Force
Copy-Item (Join-Path $EngineSource 'engine/resources_product/NOTICE.md') (Join-Path $destination 'engine/PRODUCT_PROFILES_NOTICE.md') -Force
Copy-Item (Join-Path $EngineSource 'engine/resources_product/paper_grades.json') (Join-Path $destination 'engine/paper_grades.json') -Force
New-Item -ItemType Directory -Force (Join-Path $destination 'licenses/tex-gyre-heros') | Out-Null
Copy-Item (Join-Path $EngineSource 'engine/third_party/tex-gyre-heros/*.txt') (Join-Path $destination 'licenses/tex-gyre-heros') -Force
Copy-Item (Join-Path $EngineSource 'engine/third_party/tex-gyre-heros/SOURCE.md') (Join-Path $destination 'licenses/tex-gyre-heros') -Force
