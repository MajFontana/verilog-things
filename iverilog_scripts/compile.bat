@echo off
set args =
setlocal enabledelayedexpansion
for %%f in (*.v) do set args=!args! %%f%
@echo on
C:\Programs\iverilog\bin\iverilog.exe -d eval_tree -v -W all -o test.vvp %args%
@echo off
pause