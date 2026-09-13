// EchOS 便携版 PE 版本资源模板。
//
// 构建时把 @VER_DOT@ 替换成 1.0.9、@VER_COMMA@ 替换成 1,0,9,0，
// 再用 ResourceHacker 编译成 .res 注入 SFX 模块。
//
// 为什么 LANGUAGE 必须是中性 (0,0)：
//   7zSD SFX 自带的 VERSIONINFO 语言块是 000004b0（中性语言 + 1200 代码页）。
//   如果注入成 040904b0（英文 1033），中文系统找不到匹配语言会**回退到中性语言块**，
//   右键属性里读到的仍然是 7-Zip 的版本信息（实测确认）。
//   只有用中性语言覆盖同一个 000004b0 块，才能让 Windows 读到 EchOS 的信息。
//
// 为什么 mask 用 VERSIONINFO,, 而不是 ICONGROUP：
//   图标是 ICONGROUP,101（见 build_local.ps1 / CI），版本信息是另一套资源，
//   两者要分别注入，互不影响。
LANGUAGE 0, 0

1 VERSIONINFO
FILEVERSION @VER_COMMA@
PRODUCTVERSION @VER_COMMA@
FILEFLAGSMASK 0x3fL
FILEFLAGS 0x0L
FILEOS 0x40004L
FILETYPE 0x1L
FILESUBTYPE 0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "000004b0"
        BEGIN
            VALUE "CompanyName", "dev.echos"
            VALUE "FileDescription", "EchOS Portable"
            VALUE "FileVersion", "@VER_DOT@"
            VALUE "InternalName", "EchOS"
            VALUE "LegalCopyright", "Copyright (C) 2026 dev.echos. All rights reserved."
            VALUE "OriginalFilename", "EchOS-Win-x64-Portable.exe"
            VALUE "ProductName", "EchOS"
            VALUE "ProductVersion", "@VER_DOT@"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x0000, 1200
    END
END
