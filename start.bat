@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "JAR=Server.jar"
if exist "%JAR%" goto run

for %%F in (paper-*.jar purpur-*.jar pufferfish-*.jar spigot-*.jar) do (
  set "JAR=%%F"
  goto run
)

echo No server jar found in this folder.
echo Put Server.jar here or a file like spigot-1.21.11.jar
pause
exit /b 1

:run
if not exist eula.txt (
  echo eula=true>eula.txt
) else (
  findstr /i /c:"eula=true" eula.txt >nul || (
    echo eula=true>eula.txt
  )
)

java -Xms2G -Xmx8G -jar "%JAR%" nogui
pause
