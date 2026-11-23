; The Start menu shortcut already carries BUNDLEID. A stub activator lets
; Notification Center retain protocol toasts without running a COM server.
!macro NSIS_HOOK_POSTINSTALL
  WriteRegStr SHCTX "Software\Classes\AppUserModelId\${BUNDLEID}" "DisplayName" "${PRODUCTNAME}"
  WriteRegStr SHCTX "Software\Classes\AppUserModelId\${BUNDLEID}" "CustomActivator" "{77D83D44-A55D-4A2D-AC0E-E65168D040CF}"
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  DeleteRegValue SHCTX "Software\Classes\AppUserModelId\${BUNDLEID}" "CustomActivator"
  DeleteRegValue SHCTX "Software\Classes\AppUserModelId\${BUNDLEID}" "DisplayName"
  DeleteRegKey /ifempty SHCTX "Software\Classes\AppUserModelId\${BUNDLEID}"
!macroend
