Option Explicit

Dim shell, fso, scriptDirectory, nodePath, command, argument
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fso.GetParentFolderName(WScript.ScriptFullName)
nodePath = FindOnPath("node.exe")

If nodePath = "" Then
  nodePath = shell.ExpandEnvironmentStrings("%ProgramFiles%\nodejs\node.exe")
End If

If Not fso.FileExists(nodePath) Then
  WScript.Quit 2
End If

command = Quote(nodePath) & " " & Quote(fso.BuildPath(scriptDirectory, "account-monitor.mjs"))
For Each argument In WScript.Arguments
  command = command & " " & Quote(CStr(argument))
Next

' Window style 0 guarantees that Node, Codex and gh do not take game focus.
WScript.Quit shell.Run(command, 0, True)

Function FindOnPath(fileName)
  Dim pathValue, directory, candidate
  pathValue = shell.ExpandEnvironmentStrings("%PATH%")
  For Each directory In Split(pathValue, ";")
    directory = Trim(directory)
    If directory <> "" Then
      candidate = fso.BuildPath(directory, fileName)
      If fso.FileExists(candidate) Then
        FindOnPath = candidate
        Exit Function
      End If
    End If
  Next
  FindOnPath = ""
End Function

Function Quote(value)
  Quote = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
