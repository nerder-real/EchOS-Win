# 可选拷贝 bundle 文件到产物目录：仅当源存在时执行。
# 本地开发 bundle/ 有内核/bin 数据则拷；CI（GitHub Actions）仓库无 bundle
# 二进制与 geo 数据时跳过，由构建流水线构建/下载后放置到 Release。
#
# wintun.dll 是 TUN 模式的硬依赖：内核用
# LoadLibraryEx("wintun.dll", …, LOAD_LIBRARY_SEARCH_APPLICATION_DIR
# | LOAD_LIBRARY_SEARCH_SYSTEM32) 加载它，只认「程序目录」和 System32，
# 所以必须和 x-tunnel.exe 一起落到产物目录。
if(NOT DEFINED ECHOS_OUT_DIR)
  message(FATAL_ERROR "ECHOS_OUT_DIR 未指定")
endif()
foreach(F x-tunnel.exe wintun.dll geoip.dat geosite.dat)
  if(EXISTS "${ECHOS_BUNDLE_DIR}/${F}")
    execute_process(COMMAND "${CMAKE_COMMAND}" -E copy_if_different
      "${ECHOS_BUNDLE_DIR}/${F}" "${ECHOS_OUT_DIR}/${F}")
  endif()
endforeach()