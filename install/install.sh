#!/bin/bash
disks=$(parted -l|grep 'Disk /dev'|awk '{print substr($2,1,length($2)-1)}')

max=0
for d in $disks
do
	#Finding the maximum unallocated gap of each disk
	m=$(parted $d unit B print free|
		grep Free|
		awk '{print substr($3,1,length($3)-1)}'|
		awk 'NR==1 || $1>max {max=$1} END{print max}')
	#Finding the total maximum unallocated gap of all disks
	#and also its start, end position and the disk on which it resides 
	if (("$m" > "$max"));then
		max=$m
		disk=$d
		start=$(parted $d unit B print free|
			grep Free|
			grep $m|
			awk '{print substr($1,1,length($1)-1)}')
		end=$(parted $d unit B print free|
                        grep Free|
                        grep $m|
                        awk '{print substr($2,1,length($2)-1)}')
	fi
done

#Maximum unallocated gap, it`s start and end values in gigabytes 
#10**6 and e-6 are used for getting more precise result
#because bash mostly doesn`t work with floating point numbers
#"%.2f" is the level of precision of the result (2 digits after point)
maxgb=$(printf "%.2f" $(( 10**6 *  $max / 2**30 ))e-6 )
startgb=$(printf "%.2f" $(( 10**6 *  $start / 2**30 ))e-6 )
endgb=$(printf "%.2f" $(( 10**6 *  $end / 2**30 ))e-6 )
echo ' '
echo The total maximum gap is $max bytes '(' $maxgb Gb ')' on the disk $disk 
echo Start: $start bytes '(' $startgb Gb ')', end: $end bytes '(' $endgb Gb ')'

#The number of partitions on the disk
pn=$(partx -g $disk | wc -l)
echo The disk $disk has $pn partitions

#Size of the first partition to create in bytes
s1=127775277056
#Size of the second partition to create in bytes
s2=536870912
#Total size in bytes
ts=$(($s1+$s2))
s1gb=$(printf "%.2f" $(( 10**6 * $s1 / 2**30 ))e-6 ) #In Gb's
s2gb=$(printf "%.2f" $(( 10**6 * $s2 / 2**30 ))e-6 ) #In Gb`s
tsgb=$(printf "%.2f" $(( 10**6 * $ts / 2**30 ))e-6 ) #In Gb`s
#The size control condition
if (("$max" < "$ts"));then
	echo ' '
	d=$(printf "%.2f" $(( 10**6 *  ($ts-$max) / 2**30 ))e-6 )
	echo The maximum gap $max bytes '(' $maxgb Gb ')' is smaller
	echo than the required size $ts bytes '(' $tsgb Gb ')'
	echo Please free the extra space $(($ts-$max)) bytes '(' $d Gb ')'
	exit 1
fi

q=108545 #Correction coefficient in bytes to add to start and end values to avoid warnings in fdisk

echo ' '
echo Creating the first partition in the unallocated space
start1=$(($start+$q)) #Start of the first partition
end1=$(($start+$s1)) #End of the first partition
parted -s $disk mkpart $(($pn+1)) $start1'B' $end1'B'
pn=$(partx -g $disk | wc -l) #Updating the number of partitions on the disk
#New partition name
np=$(fdisk -l $disk | grep /dev/ | awk '{print $1}' | awk 'END{print}')
echo Created partition $np $s1 bytes '(' $s1gb ')' Gb
echo ' '
echo Restoring the first partition $np from the backup:
echo ' '
img1=AstraV5-230323/AstraV5-230323.img/nvme0n1p2.ext4-ptcl-img.gz.a*
#*an asterisk is for the image split into multiple files to make it restore correctly
#because there`s also a similar file with the .ab extension in the backup folder
cat $img1 | gunzip -c | partclone.ext4 -r -s - -o $np
echo ' '

echo ' '
echo Creating the second partition in unallocated space
start2=$(($end1+$q)) #Start of the second partition
end2=$(($start2+$s2)) #End of the second partition
parted -s $disk mkpart $(($pn+1)) $start2'B' $end2'B'
pn=$(partx -g $disk | wc -l) #Updating the number of partitions on the disk
#New partition name
np=$(fdisk -l $disk | grep /dev/ | awk '{print $1}' | awk 'END{print}')
echo Created partition $np $s2 bytes '(' $s2gb ')' Mb
echo ' '
echo Restoring the second partition $np from the backup:
echo ' '
img2=AstraV5-230323/AstraV5-230323.img/nvme0n1p1.vfat-ptcl-img.gz.aa
cat $img2 | gunzip -c | partclone.fat32 -r -s - -o $np
echo ' '

echo Installing GRUB to the Windows EFI partition:
echo ' '
efi=$(fdisk -l $disk | grep /dev/ | grep EFI | awk '{print $1}') #Windows EFI partition
astra=$(fdisk -l $disk | grep /dev/ | grep Linux | awk '{print $1}' | head -1) #Astra Linux data partition

echo Creating the temporary EFI and Linux directories in /mnt
efidir=/mnt/efi
astradir=/mnt/astra
mkdir $efidir
mkdir $astradir

echo Mounting the EFI and Linux partitions to these directories
mount $efi $efidir
mount $astra $astradir

echo Mounting system directories to system subdirectries of the Linux directory
mount --bind /dev $astradir/dev
mount --bind /sys $astradir/sys
mount --bind /proc $astradir/proc

echo Installing GRUB
grub-install $disk --root-directory=$astradir --efi-directory=$efidir

echo Unmounting all temporary directories
umount $astradir/dev
umount $astradir/sys
umount $astradir/proc
umount $astradir
umount $efidir

echo Deleting temporary directories
rm -r $efidir
rm -r $astradir
