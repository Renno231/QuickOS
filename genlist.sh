#!/bin/bash
shopt -s dotglob
output=""

#declare -A exclusions
exclusions=("/files.txt", "/genlist.sh", "/bin/main.lua", "/.gitignore")

push() {
  if [[ ${exclusions[@]} =~ $1 ]]; then
    return
  fi

  output+="$1\n"
}

recursive() {
  cd $1
  for file in *; do
    if [ $file == '*' ]; then
      continue
    fi
    if [ -d "$file" ]; then
      recursive "$file" "$2$1/"
    else
      push "/$2$1/$file"
    fi
  done
  cd ..
}

for file in *; do
  if [ $file == ".git" ]; then
    continue
  elif [ -d "$file" ]; then
    recursive "$file"
  else
    push "/$file"
  fi
done

shopt -u dotglob
printf "$output" > files.txt
