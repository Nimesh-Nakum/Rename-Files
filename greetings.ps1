# we have to take Name and the greeting messgage from the User (read-Host) without parameters or use parameters
#we can provide loud, verbose options to the user ,
# so basically what parameters we need is Name , Verbose, Message (may be opitonal), Loud


param(
    [parameter(Mandatory=$true, HelpMessage="The Name to Greet")]
    [string]$Name,

    [Parameter(HelpMessage="Message to Greeet")]
    [string]$Message = "Hello",

    [switch]$Loud
    
)

if($Loud){
    Write-Host "$($Message.ToUpper()) $($Name.ToUpper())"
}else{
    Write-Host "$Message $Name"
}

if($Verbose){
    Write-Verbose "Greeting generated for $Name with Message '$Message'. "
}



