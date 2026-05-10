(*
  Double-clickable launcher (optional): compile to an application with:
    osacompile -o "Media Magic.app" LaunchMediaPipeline.applescript

  Before compiling, set pipelineScript below to the absolute path of
  MediaConversionPipeline.sh on your Mac Studio.

  The shell script performs all native dialogs (osascript); this launcher
  only opens Terminal so the interactive session has a visible transcript.
*)
property pipelineScript : "/usr/local/bin/MediaConversionPipeline.sh"

on run
	set q to quoted form of pipelineScript
	tell application "Terminal"
		do script "/bin/bash " & q
		activate
	end tell
end run
