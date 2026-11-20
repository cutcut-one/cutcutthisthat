#!/bin/bash
# Tạo 3 clip mẫu tự sinh (không phải clip khách): màu + giọng `say` tiếng Việt nếu có giọng Linh.
set -euo pipefail
out=$1; mkdir -p "$out"; cd "$out"
v=$(say -v '?' | awk '/vi_VN/{print $1; exit}')
lines=("Xin chào các chị, hôm nay em chỉ cách lau kính cho thật sạch" "Đầu tiên các chị pha nước với một chút giấm" "Cuối cùng lau khô bằng khăn mềm là kính sáng bóng")
cols=(red green blue)
for i in 0 1 2; do
  say ${v:+-v "$v"} -o "a$i.aiff" "${lines[$i]}"
  ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1080x1920:rate=30" -i "a$i.aiff" \
    -vf "drawbox=c=${cols[$i]}@0.3:t=fill" -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac "clip$i.mp4"
  rm "a$i.aiff"
done
echo "voice=${v:-default}"
