#!/bin/bash
disks=$(parted -l|grep 'Disk /dev'|awk '{print substr($2,1,length($2)-1)}')

max=0
for d in $disks
do
	#Finding the maximum unallocated gap of each disk
	m=$(parted $d unit s print free|
		grep Free|
		awk '{print substr($3,1,length($3)-1)}'|
		awk 'NR==1 || $1>max {max=$1} END{print max}')
	#Finding the total maximum unallocated gap of all disks
	#and also its start, end position and the disk on which it resides 
	if (("$m" > "$max"));then
		max=$m
		disk=$d
		start=$(parted $d unit s print free|
			grep Free|
			grep $m|
			awk '{print substr($1,1,length($1)-1)}')
		end=$(parted $d unit s print free|
                        grep Free|
                        grep $m|
                        awk '{print substr($2,1,length($2)-1)}')
	fi
done

#Maximum unallocated gap, it`s start and end values in gigabytes 
#10**6 and e-6 are used for getting more precise result
#because bash mostly doesn`t work with floating point numbers
#"%.2f" is the level of precision of the result (2 digits after point)
maxgb=$(printf "%.2f" $(( 10**6 *  $max * 512 / 2**30 ))e-6 )
startgb=$(printf "%.2f" $(( 10**6 *  $start * 512 / 2**30 ))e-6 )
endgb=$(printf "%.2f" $(( 10**6 *  $end * 512 / 2**30 ))e-6 )
echo ' '
echo The total maximum gap is $max sectors '(' $maxgb Gb ')' on the disk $disk 
echo Start: $start sectors '(' $startgb Gb ')', end: $end sectors '(' $endgb Gb ')'

#The number of partitions on the disk
pn=$(partx -g $disk | wc -l)
echo The disk $disk has $pn partitions
echo ''

#Finding sizes of the partitions to be copied
#Getting the required partition sizes from
#the Clonezilla system file
pd=$(find -type f -iname *parted)
pd=${pd:2}
echo The path to the file with the partiton data:
echo $pd
echo ''

#EXT4 partition size in sectors
s1=$(cat $pd|grep fat32|awk '{print $4}'|tr -dc '0-9')
#FAT32 size in sectors
s2=$(cat $pd|grep ext4|awk '{print $4}'|tr -dc '0-9')
#Total size in sectors
ts=$(($s1+$s2))

s1gb=$(printf "%.2f" $(( 10**6 * $s1 * 512 / 2**30 ))e-6 ) #In Gb's
s2gb=$(printf "%.2f" $(( 10**6 * $s2 * 512 / 2**30 ))e-6 ) #In Gb`s
tsgb=$(printf "%.2f" $(( 10**6 * $ts * 512 / 2**30 ))e-6 ) #In Gb`s
echo The FAT32 partition size is $s1 sectors '(' $s1gb Gb ')'
echo The EXT4 partition size is $s2 sectors '(' $s2gb Gb ')'
echo The total size of 2 partitions is $ts sectors '(' $tsgb Gb ')'

#The size control condition
if (("$max" < "$ts"));then
	echo ' '
	d=$(printf "%.2f" $(( 10**6 * ($ts-$max) * 512 / 2**30 ))e-6 )
	echo The maximum gap $max sectors '(' $maxgb Gb ')' is smaller
	echo than the required size $ts sectors '(' $tsgb Gb ')'
	echo Please free the extra space $(($ts-$max)) sectors '(' $d Gb ')'
	exit 1
fi

echo ' '
echo Creating the first partition in the unallocated space
mid=$(($start+$s1)) #End of the first partition
parted -s $disk mkpart $(($pn+1)) $start's' $mid's'
pn=$(partx -g $disk | wc -l) #Updating the number of partitions on the disk
#New partition name
np=$(fdisk -l $disk | grep /dev/ | awk '{print $1}' | awk 'END{print}')
echo Created partition $np $s1 sectors '(' $s1gb ')' Gb
echo ' '
#Finding the path to the FAT32 partition backup
fp1=*nvme0n1p1*
img1=$(find -type f -iname $fp1) #Finding the path to file(s)
#with "nvme0n1p2" in names
lp1=$(find -type f -iname $fp1|wc -l) #Number of lines in the find command output
if(($lp1>1))
then
	img1=$(find -type f -iname $fp1|head -1) #First line
	img1=${img1%/*}
	img1+=/$fp1
fi
img1=${img1:2}
echo The path'('s')' to FAT32 file'('s')' backup'('s')':
echo $img1
echo ''
echo Restoring the first partition $np from the backup:
echo ' '
cat $img1 | gunzip -c | partclone.fat32 -r -s - -o $np
echo ' '

echo ' '
echo Creating the second partition in the unallocated space
parted -s $disk mkpart $(($pn+1)) $(($mid+1))'s' $(($mid+1+$s2))'s'
pn=$(partx -g $disk | wc -l) #Updating the number of partitions on the disk
#New partition name
np=$(fdisk -l $disk | grep /dev/ | awk '{print $1}' | awk 'END{print}')
echo Created partition $np $s2 sectors '(' $s2gb ')' Gb
echo ' '
#Finding the path to the EXT4 partition backup
fp2=*nvme0n1p2*
img2=$(find -type f -iname $fp2) #Finding the path to file(s)
#with "nvme0n1p2" in names
lp2=$(find -type f -iname $fp2|wc -l) #Number of lines in the find command output
if(($lp2>1))
then
	img2=$(find -type f -iname $fp2|head -1) #First line
	img2=${img2%/*}
	img2+=/$fp2
fi
img2=${img2:2}
echo The path'('s')' to EXT4 file'('s')' backup'('s')':
echo ''
echo $img2
echo Restoring the second partition $np from the backup:
echo ' '
cat $img2 | gunzip -c | partclone.ext4 -r -s - -o $np
echo ' '
if(( $(bc<<<"$(bc<<<$maxgb-$tsgb) > 1.0") ))
then
	echo Extending the EXT4 $np partition to occupy the unallocated space after it
	parted $disk resizepart $pn $(echo "$endgb-0.2"|bc)GiB
	e2fsck -f $np
	resize2fs $np
fi
echo ' '
echo Installing GRUB to the Windows EFI partition:
echo ' '
efi=$(fdisk -l $disk | grep /dev/ | grep EFI | awk '{print $1}') #Windows EFI partition
astra=$(fdisk -l $disk | grep /dev/ | grep Linux | awk '{print $1}' | tail -1) #Astra Linux data partition
# Linux EFI patition (first restored FAT32 partition) in case of absense of the Windows one
if [ "$efi" == "" ]
then efi=$(fdisk -l $disk | grep /dev/ | grep Linux | awk '{print $1}' | head -1)
fi

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
