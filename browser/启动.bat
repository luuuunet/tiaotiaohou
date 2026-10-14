@echo off
chcp 65001 >nul
cd /d "%~dp0"
"%~dp0tiaotiaohou-browser.exe" --install
echo.
echo 如果上面显示成功，打开 Chrome 或 Edge 的扩展页面，
echo 打开开发者模式，点「加载解压缩的扩展」，
echo 选中本目录里的 extension 文件夹。
echo 然后填节点地址和令牌，点开始连接。
pause
