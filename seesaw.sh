#!/bin/bash
#
# Distributed downloading script for me.com/mac.com.
#
# This script will download a user's data to this computer.
# It uploads the data to batcave and deletes it. It will then
# continue with the next user and repeat.
#
# Usage:
#   ./seesaw.sh $YOURNICK
#
# You can set a bwlimit for the rsync upload, e.g.:
#   ./seesaw.sh $YOURNICK 300
#
# To stop the script gracefully,  touch STOP  in the script's
# working directory. The script will then finish the current
# user and stop.
#

# this script needs wget-warc, which you can find on the ArchiveTeam wiki.
# copy the wget executable to this script's working directory and rename
# it to wget-warc

if [ ! -x ./wget-warc ]
then
  echo "wget-warc not found. Download and compile wget-warc and save the"
  echo "executable as ./wget-warc"
  exit 3
fi

# the script also needs curl with SSL support

if ! builtin type -p curl &>/dev/null
then
  echo "You don't have curl."
  exit 3
fi

if ! curl -V | grep -q SSL
then
  echo "Your version of curl doesn't have SSL support."
  exit 3
fi

if [ -z $DATA_DIR ]
then
  DATA_DIR=data
fi

youralias="$1"
bwlimit=$2

if [[ ! $youralias =~ ^[-A-Za-z0-9_]+$ ]]
then
  echo "Usage:  $0 {nickname}"
  echo "Run with a nickname with only A-Z, a-z, 0-9, - and _"
  exit 4
fi

if [ -n "$bwlimit" ]
then
  bwlimit="--bwlimit=${bwlimit}"
fi

initial_stop_mtime='0'
if [ -f STOP ]
then
  initial_stop_mtime=$( ./filemtime-helper.sh STOP )
fi

VERSION=$( grep 'VERSION=' dld-me-com.sh | grep -oE "[-0-9.]+" )

while [ ! -f STOP ] || [[ $( ./filemtime-helper.sh STOP ) -le $initial_stop_mtime ]]
do
  # request a username
  echo -n "Getting next username from tracker..."
  tracker_no=$(( RANDOM % 3 ))
  tracker_host="memac-${tracker_no}.heroku.com"
  username=$( curl -s -f -d "{\"downloader\":\"${youralias}\"}" http://${tracker_host}/request )

  # empty?
  if [ -z $username ]
  then
    echo
    echo "No username. Sleeping for 30 seconds..."
    echo
    sleep 30
  else
    echo " done."

    if ! ./dld-user.sh "$username"
    then
      echo "Error downloading '$username'."
      exit 6
    fi

    # statistics!
    i=0
    bytes_str="{"
    domains="web.me.com public.me.com gallery.me.com homepage.mac.com"
    for domain in $domains
    do
      userdir="$DATA_DIR/${username:0:1}/${username:0:2}/${username:0:3}/${username}/${domain}"
      if [ -d $userdir ]
      then
        if du --help | grep -q apparent-size
        then
          bytes=$( du --apparent-size -bs $userdir | cut -f 1 )
        else
          bytes=$( du -bs $userdir | cut -f 1 )
        fi
        if [[ $i -ne 0 ]]
        then
          bytes_str="${bytes_str},"
        fi
        bytes_str="${bytes_str}\"${domain}\":${bytes}"
        i=$(( i + 1 ))
      fi
    done
    bytes_str="${bytes_str}}"

    # some more statistics
    ids=($( grep -h -oE "<id>urn:apple:iserv:[^<]+" \
              "$DATA_DIR/${username:0:1}/${username:0:2}/${username:0:3}/${username}/"*"/webdav-feed.xml" \
              | cut -c 21- | sort | uniq ))
    id=0
    if [[ ${#ids[*]} -gt 0 ]]
    then
      id="${#ids[*]}:${ids[0]}:${ids[${#ids[*]}-1]}"
    fi

    success_str_done="{\"downloader\":\"${youralias}\",\"user\":\"${username}\",\"bytes\":${bytes_str},\"version\":\"${VERSION}\",\"id\":\"${id}\"}"

    userdir="${username:0:1}/${username:0:2}/${username:0:3}/${username}"
    target=fos
    dest=${target}.textfiles.com::mobileme/$1/
    echo "Uploading $user"

    result=-1
    while [ $result -ne 0 ]
    do
      echo "${userdir}" | \
      rsync -avz --partial \
            --compress-level=9 \
            --progress \
            ${bwlimit} \
            --exclude=".incomplete" \
            --exclude="files" \
            --exclude="unique-urls.txt" \
            --recursive \
            --files-from="-" \
            $DATA_DIR/ ${dest}
      result=$?

      if [ $result -ne 0 ]
      then
        echo "An rsync error. Waiting 10 seconds before trying again..."
        sleep 10
      fi
    done

    if [ $result -eq 0 ]
    then
      echo -n "Upload complete. Notifying tracker... "

      success_str="{\"uploader\":\"${youralias}\",\"user\":\"${username}\",\"server\":\"${target}\"}"

      delay=1
      while [ $delay -gt 0 ]
      do
        tracker_no=$(( RANDOM % 3 ))
        tracker_host="memac-${tracker_no}.heroku.com"
        resp=$( curl -s -f -d "$success_str" http://${tracker_host}/uploaded )
        if [[ "$resp" != "OK" ]]
        then
          echo "ERROR contacting tracker. Could not mark '$username' done."
          echo "Sleep and retry."
          sleep $delay
          delay=$(( delay * 2 ))
        else
          delay=0
        fi
      done
      
      rm -rf $DATA_DIR/$userdir

      echo "done."
      echo
      echo
    else
      echo
      echo
      echo "An rsync error. Scary!"
      echo
      exit 1
    fi

    delay=1
    while [ $delay -gt 0 ]
    do
      echo "Telling tracker that '${username}' is done."
      tracker_no=$(( RANDOM % 3 ))
      tracker_host="memac-${tracker_no}.heroku.com"
      resp=$( curl -s -f -d "$success_str_done" http://${tracker_host}/done )
      if [[ "$resp" != "OK" ]]
      then
        echo "ERROR contacting tracker. Could not mark '$username' done."
        echo "Sleep and retry."
        sleep $delay
        delay=$(( delay * 2 ))
      else
        delay=0
      fi
    done
    echo
  fi
done

