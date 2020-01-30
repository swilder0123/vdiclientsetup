$computerName = $env:COMPUTERNAME
$windowsPath = $env:SYSTEMROOT
$odjTemp = "c:\odjtemp"

$blobRoot = "https://cpowereast.blob.core.windows.net/clients/$computerName-odj.txt"

if(!(get-item -Path $odjTemp -ErrorAction Ignore)) {
	mkdir -Path $odjTemp 
}

$odjFile = $odjTemp + "\odjfile.txt"

$getBlob = ""

try {
    $getBlob = wget -UseBasicParsing -Uri "https://cpowereast.blob.core.windows.net/clients/$computerName-odj.txt"
}
catch [System.Net.WebException] {
    write-output "The ODJ blob was not found in the storage container."
}
catch {
    write-output "Some error occurred when attempting to fetch the data..."
    write-output $error[0].Exception
}

$getBlob.Content | Set-Content -Path $odjFile

djoin /requestODJ /loadfile $odjFile /windowspath $windowsPath /localos

remove-item -recurse $odjTemp

write-output "Script completed successfully."