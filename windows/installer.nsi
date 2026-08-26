; Snippr for Windows - NSIS installer (built cross-platform with makensis)
!include "MUI2.nsh"

Name "Snippr"
OutFile "SnipprSetup-1.2.18-win-x64.exe"
InstallDir "$PROGRAMFILES64\Snippr"
InstallDirRegKey HKLM "Software\Snippr" "InstallDir"
RequestExecutionLevel admin
Unicode true
SetCompressor /SOLID lzma

!define MUI_ICON "snippr.ico"
!define MUI_UNICON "snippr.ico"
!define MUI_FINISHPAGE_RUN "$INSTDIR\Snippr.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch Snippr now"

!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Section "Snippr"
  ; kill any running copy so the update actually replaces it
  ExecWait 'taskkill /F /IM Snippr.exe' $0
  SetOutPath "$INSTDIR"
  File "Snippr.exe"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "Software\Snippr" "InstallDir" "$INSTDIR"

  CreateDirectory "$SMPROGRAMS\Snippr"
  CreateShortcut "$SMPROGRAMS\Snippr\Snippr.lnk" "$INSTDIR\Snippr.exe"
  CreateShortcut "$SMPROGRAMS\Snippr\Uninstall Snippr.lnk" "$INSTDIR\Uninstall.exe"

  ; Add/Remove Programs entry
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Snippr" "DisplayName" "Snippr"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Snippr" "DisplayVersion" "1.2.18"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Snippr" "Publisher" "Snippr (open source)"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Snippr" "URLInfoAbout" "https://snippr.pages.dev"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Snippr" "DisplayIcon" "$INSTDIR\Snippr.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Snippr" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Snippr" "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Snippr" "NoRepair" 1
SectionEnd

Section "Uninstall"
  ; stop app if running
  ExecWait 'taskkill /F /IM Snippr.exe' $0

  Delete "$INSTDIR\Snippr.exe"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Snippr\Snippr.lnk"
  Delete "$SMPROGRAMS\Snippr\Uninstall Snippr.lnk"
  RMDir "$SMPROGRAMS\Snippr"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Snippr"
  DeleteRegKey HKLM "Software\Snippr"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Snippr"
SectionEnd
