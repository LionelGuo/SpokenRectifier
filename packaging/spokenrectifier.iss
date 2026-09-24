; Inno Setup script for the SpokenRectifier per-user installer.
; Compile via packaging/build-release.ps1, which passes /DMyAppVersion from
; app/pubspec.yaml; the fallback below is only for direct ISCC runs.
;
; Form factors decided in the installer-options research (2026-09-24):
; per-user install (PrivilegesRequired=lowest, %LOCALAPPDATA%\Programs),
; no UAC prompt, standard uninstall entry. The zip attachment covers the
; portable case; this installer is the primary download.

#ifndef MyAppVersion
#define MyAppVersion "1.0.0"
#endif

#define MyAppName "SpokenRectifier"
#define MyAppPublisher "LionelGuo"
#define MyAppURL "https://github.com/LionelGuo/SpokenRectifier"
#define MyAppExeName "spokenrectifier_app.exe"
; Staged by build-release.ps1 from app\build\windows\x64\runner\Release with
; runtime artifacts (local store db, perf log, local config) filtered out.
#define PayloadDir "..\dist\release-stage\payload"

[Setup]
AppId={{E238524E-524B-41D8-87DF-CFFE82D825F4}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\Programs\{#MyAppName}
PrivilegesRequired=lowest
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=SpokenRectifier-Setup-{#MyAppVersion}

[Languages]
; The Simplified Chinese messages ship in the issrc tree but not in the
; installer package, so the official translation file is vendored here.
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
chinesesimplified.AutoStartGroup=其他选项:
chinesesimplified.AutoStartTask=开机自动启动 SpokenRectifier(可随时在应用设置中开关)
english.AutoStartGroup=Additional options:
english.AutoStartTask=Start SpokenRectifier automatically when Windows starts (toggleable later in the app settings)

[Tasks]
; Unchecked by default per the open-restraint posture ruled in the autostart
; ticket; Inno remembers the previous choice on reinstall by itself.
Name: "autostart"; Description: "{cm:AutoStartTask}"; GroupDescription: "{cm:AutoStartGroup}"; Flags: unchecked
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole payload directory rides along (exe, flutter_windows.dll, data/,
; Rust dylib) — missing pieces here are the classic blank-window failure.
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Registry]
; Single source of truth with the in-app switch: HKCU Run value
; "SpokenRectifier", quoted full exe path, no arguments.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "SpokenRectifier"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: autostart

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  ResultCode: Integer;

// A running instance locks the exe/dlls, so upgrades and uninstalls must
// close it first. Restart Manager proved unreliable for this tray/orb app
// (no ordinary visible main window) and WM_CLOSE only hides it, hence the
// force kill — the app holds no unsaved state (history writes through to
// the store). Matching is by image name, so it also closes a running
// build from another location of the same product.
procedure KillRunningApp();
begin
  Exec(ExpandConstant('{cmd}'), '/C taskkill /IM spokenrectifier_app.exe /F',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    KillRunningApp();
end;

// Uninstall must clear the autostart Run key unconditionally: the in-app
// settings switch (not only this installer's checkbox) may have written it,
// and uninsdeletevalue only covers the installer-written entry.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    KillRunningApp();
    RegDeleteValue(HKEY_CURRENT_USER,
      'Software\Microsoft\Windows\CurrentVersion\Run', 'SpokenRectifier');
  end;
end;
