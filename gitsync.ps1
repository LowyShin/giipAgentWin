$hn = (Get-CimInstance -Class Win32_ComputerSystem).Name

git pull origin real

git add .

git commit -m "auto sync from $hn"

git push origin real
