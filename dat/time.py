import time
import os

localtime = time.asctime( time.localtime(time.time()) )

file = "C:/git_ws/BbB/dat/time.txt"

i = 98

while (i <= 100):
    print(i)
    source =  open(file, 'a' )
    temp = localtime
    print(temp, file=source)
    i += 1
    os.system('git add . ')
    os.system('git commit -m "updated version')
    os.system('git push')