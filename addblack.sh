#!/bin/bash

# Script to add second of black to beginning & end of input video

# INITIALIZE

# Capture command-line arguments
while [[ $# > 1 ]]; do
	key="$1"
	case $key in
		-i|--input)
	    	in_path="$2"
	    	shift;shift;; # past arguments
		-c|--code)
	    	in_code="$2"
	    	shift # past arguments
			shift
	    	;;
		-d|--duration)
			in_dura="$2"
			shift
			shift
			;;
		-t|--timecode)
			in_tico="$2"
			shift
			shift
			;;
		*)  
	    	;; # unknown/no option
	esac
done

echo $in_dura

if [[ -z in_dura ]]; then in_dura=1; fi
if [[ -z in_tico ]]; then in_tico="00:00:00:00"; fi

# Assign & create temporary directory for intermediate files
tempdir=/tmp/sl_mill/
mkdir -p "$tempdir"

# Binary paths
ffmpeg_path=/jobs/transfer/2d_Tools/SamLloyd_Scripts/Applications_Server/__binaries/ffmpeg/ffmpeg
ffprobe_path=/jobs/transfer/2d_Tools/SamLloyd_Scripts/Applications_Server/__binaries/ffmpeg/ffprobe


## GATHER INPUT DETAILS ##

filename=$(basename "$in_path")
working_filepath="$tempdir""$filename"


# Store metadata of input streams in variables
v_probe=$("$ffprobe_path" -v error -select_streams v:0 -show_entries stream "$in_path")
a_probe=$("$ffprobe_path" -v error -select_streams a:0 -show_entries stream "$in_path")

# Subroutine to easily grab values from probe results
# Variables of interest: avg_frame_rate,coded_width,coded_height,codec_name
function get_probe_value { results="$1"; key="$2"; printf "${results[@]}" | grep "$key" | grep -o "=".* | cut -c 2-; }

vid_codec_in=$(get_probe_value "$v_probe" "codec_name")
aud_codec_in=$(get_probe_value "$a_probe" "codec_name")
width_in=$(get_probe_value "$v_probe" "coded_width")
height_in=$(get_probe_value "$v_probe" "coded_height")
vid_codec_pretty=$(get_probe_value "$v_probe" "encoder")

aud_stream_count=$("$ffprobe_path" -v error -select_streams a -show_entries stream "$in_path" | grep -c "\[STREAM\]")


## CREATE & CONCATENATE ##

# Create second of black and silence at source resolution & framerate
# Using -map, copy source AV configuration, ignoring any other channels
blacksec="$tempdir"blacksec.mov

"$ffmpeg_path" -i "$in_path" -t $in_dura -vf colorlevels=rimax=0:gimax=0:bimax=0,negate=0 -af volume=0 \
-map 0:v -map 0:a? -vcodec $vid_codec_in -acodec $aud_codec_in -y "$blacksec"

# Add black second at beginning and end of source clip
# Filter technique inspired by code by Lou Logan & Thomas Demirian: https://forums.creativecow.net/thread/291/1315
filter_a="[0:v]"
filter_b="[1:v]"
filter_c="[2:v]"
filter_list="[v]"
map_list="-map [v]"

for ((i = 1 ; i <= $aud_stream_count ; i++)); do
	iminusone=$(($i-1))
	filter_a=$filter_a' '[0:a:$iminusone]
	filter_b=$filter_b' '[1:a:$iminusone]
	filter_c=$filter_c' '[2:a:$iminusone]
	filter_list=$filter_list' '"[a$i]"
	map_list=$map_list' '"-map [a$i]"
done

if [[ $in_code -eq 1 ]]; then
	inputs="-i $blacksec -i $in_path"
	filter_string="$filter_a$filter_b concat=n=2:v=1:a=$aud_stream_count $filter_list"
elif [[ $in_code -eq 2 ]]; then
	inputs="-i $in_path -i $blacksec"
	filter_string="$filter_a$filter_b concat=n=2:v=1:a=$aud_stream_count $filter_list"
elif [[ $in_code -eq 3 ]]; then
	inputs="-i $blacksec -i $in_path -i $blacksec"
	filter_string="$filter_a$filter_b$filter_c concat=n=3:v=1:a=$aud_stream_count $filter_list"
fi 

"$ffmpeg_path" $inputs -metadata:s encoder="$vid_codec_pretty" -filter_complex "$filter_string" $map_list \
-movflags +write_colr -timecode "$in_tico" -c:v $vid_codec_in -c:a $aud_codec_in -y "$working_filepath"



# MANUALLY FIX TRACK ATOMS FOR MULTISTREAM AUDIO 

# To my knowledge, ffmpeg can only encode one active stream of audio (without using copy);
# the others are rendered inactive until reenabled.
# I couldn't find a tool to fix this, so I made my own. The below finds inactive tracks and enables them.

if (( $aud_stream_count > 1 )); then
# '746b6864' is 'tkhd' hex atom marker
# flag marker is at 4th subsequent byte, should be '0f'
# alt grp marker is at 72nd subsequent byte, should be '00'
# detect if either value is different
tkhd_nuclei_old=$(xxd -p "$working_filepath" | tr -d '\n' | egrep -o '746b6864(.{7}[^f].{64}|.{71}[^0])')
echo "OLD ONES "$tkhd_nuclei_old
# Fix if different.
# Create array of strings for substitution
for each_nucleus in $tkhd_nuclei_old; do
	tkhd_nucleus_old=$(echo $each_nucleus | sed 's/.\{2\}/\\x&/g')
	echo "OLD ONE "$tkhd_nucleus_old
    tkhd_nucleus_new=$(echo $each_nucleus | sed s/./f/16 | sed s/./0/80 | sed 's/.\{2\}/\\x&/g')
    echo "NEW ONE "$tkhd_nucleus_new
    perl -pi -e "s/$tkhd_nucleus_old/$tkhd_nucleus_new/" "$working_filepath"
done
fi

#use -vf "fps=$framerate_in" for constant frame rate..


# Clean up
cp -f "$working_filepath" "$in_path"
rm -R "$tempdir"


