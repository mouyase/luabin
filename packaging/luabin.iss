; luabin — Inno Setup 安装包脚本
;
; 由 workflow 的 PowerShell 步骤调用：
;   & "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" `
;       /DStageDir=<stage 绝对路径> `
;       /DTag=<lua-5.5.1-windows-x64> `
;       /DVersion=5.5.1 `
;       /DArch=x64 `
;       /DOutDir=<输出目录> `
;       packaging\luabin.iss
;
; 不签名：Windows 会弹 SmartScreen 的「更多信息 → 仍要运行」，
; 属于警告而非拦截。

#ifndef StageDir
  #error 需要 /DStageDir=<stage 目录>`
#endif
#ifndef Tag
  #error 需要 /DTag=<产物名>`
#endif
#ifndef Version
  #error 需要 /DVersion=<版本号>`
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef OutDir
  #define OutDir "."
#endif

#define AppName "Lua"
#define AppPublisher "PUC-Rio"
#define AppURL "https://www.lua.org/"
#define AppId "cn.yojigen.luabin"

[Setup]
AppId={#AppId}
AppName={#AppName} {#Version}
AppVersion={#Version}
AppVerName={#AppName} {#Version} ({#Arch})
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
DefaultDirName={autopf}\Lua\{#Version}
DefaultGroupName=Lua {#Version}
DisableProgramGroupPage=yes
LicenseFile={#StageDir}\LICENSE
OutputDir={#OutDir}
OutputBaseFilename={#Tag}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed={#Arch}
ArchitecturesInstallIn64BitMode={#Arch}
ChangesEnvironment=yes
UninstallDisplayName={#AppName} {#Version} ({#Arch})
PrivilegesRequired=admin
AllowNoIcons=yes

; 简体中文语言文件在 Inno 各版本里位置不同：
;   6.7+  → Languages\ChineseSimplified.isl
;   6.5.x → Languages\Unofficial\ChineseSimplified.isl
; 且旧版本可能根本没带。用 FileExists 做条件编译，
; 找不到就只保留英文，保证 ISCC 一定能编过。
[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#elif FileExists(AddBackslash(CompilerPath) + "Languages\Unofficial\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\Unofficial\ChineseSimplified.isl"
#elif FileExists(AddBackslash(SourcePath) + "ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
#endif

[Tasks]
Name: "addtopath"; Description: "把 Lua 加入系统 PATH（推荐）"; GroupDescription: "环境配置:"
Name: "associate"; Description: "关联 .lua 文件（双击运行脚本）"; GroupDescription: "环境配置:"; Flags: unchecked

[Files]
Source: "{#StageDir}\bin\lua.exe";        DestDir: "{app}\bin"; Flags: ignoreversion
Source: "{#StageDir}\bin\luac.exe";       DestDir: "{app}\bin"; Flags: ignoreversion
Source: "{#StageDir}\bin\lua55.dll";      DestDir: "{app}\bin"; Flags: ignoreversion
Source: "{#StageDir}\include\*";          DestDir: "{app}\include"; Flags: ignoreversion
Source: "{#StageDir}\lib\*";              DestDir: "{app}\lib"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#StageDir}\share\lua\5.5\*";    DestDir: "{app}\share\lua\5.5"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
Source: "{#StageDir}\BUILD-INFO";         DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\README-lua.html";    DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#StageDir}\LICENSE";           DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{group}\Lua {#Version} 命令行"; Filename: "{cmd}"; Parameters: "/k ""{app}\bin\lua.exe"" -v"; WorkingDir: "{app}"; Comment: "打开带 Lua 的命令行"
Name: "{group}\卸载 Lua {#Version}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\bin\lua.exe"; Parameters: "-v"; Description: "验证安装"; Flags: postinstall nowait skipifsilent runhidden
Filename: "{app}\README-lua.html"; Description: "查看 Lua 文档"; Flags: postinstall shellexec nowait skipifsilent unchecked

[Registry]
; PATH：只在勾选 addtopath 时写入，卸载时移除
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; \
  ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}\bin"; \
  Tasks: addtopath; Check: NeedsAddPath('{app}\bin')

; .lua 文件关联：只写 HKCU，避免影响其他用户
Root: HKCU; Subkey: "Software\Classes\.lua"; ValueType: string; ValueName: ""; \
  ValueData: "Lua.Script"; Tasks: associate; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\Lua.Script"; ValueType: string; ValueName: ""; \
  ValueData: "Lua Script"; Tasks: associate; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Lua.Script\shell\open\command"; ValueType: string; \
  ValueName: ""; ValueData: """{app}\bin\lua.exe"" ""%1"""; Tasks: associate

[Code]
// 已经存在同名 PATH 段时不再重复追加
function NeedsAddPath(Param: string): Boolean;
var
  OrigPath: string;
begin
  if not RegQueryStringValue(HKEY_LOCAL_MACHINE,
    'SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
    'Path', OrigPath) then
  begin
    Result := True;
    exit;
  end;
  // 用分号包住再找，避免子串误匹配（如 C:\Lua 命中 C:\Lua55）
  Result := Pos(';' + Uppercase(Param) + ';', ';' + Uppercase(OrigPath) + ';') = 0;
end;

// 卸载时从 PATH 里摘掉自己
procedure RemoveFromPath(AppDir: string);
var
  Path: string;
  P: Integer;
begin
  if not RegQueryStringValue(HKEY_LOCAL_MACHINE,
    'SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
    'Path', Path) then
    exit;
  P := Pos(';' + Uppercase(AppDir), ';' + Uppercase(Path));
  if P > 0 then
  begin
    Delete(Path, P, Length(AppDir) + 1);
    RegWriteExpandStringValue(HKEY_LOCAL_MACHINE,
      'SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
      'Path', Path);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemoveFromPath(ExpandConstant('{app}\bin'));
end;
