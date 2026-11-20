@echo off
cd /d "%~dp0"
set JAVA=java
for /d %%D in (java-tmp\jdk-25*) do if exist "%%D\bin\java.exe" set JAVA=%%D\bin\java.exe
if exist "java\bin\java.exe" set JAVA=java\bin\java.exe
if exist "plugins-disabled\FancyNpcs-2.12.1.jar" move /-Y "plugins-disabled\FancyNpcs-2.12.1.jar" "plugins\" >nul
echo Using Java: %JAVA%
"%JAVA%" -Xms2G -Xmx8G -jar paper-1.21.11.jar nogui
pause
