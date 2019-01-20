function Install-CosnulWithWMIExporter {
    param (

        ### All these variables can be changed based on whatever your enviornmental needs are ###
    
        # Where we will be storing our files
        $downloadDirectory = $env:TEMP,

        # The version of Go that we want to download
        $goVersion = "1.9",

        # Where go is downloaded from
        $goURL = "https://storage.googleapis.com/golang/go" + $goVersion + ".windows-amd64.zip",

        # Root directory of go
        $goRoot = "C:\Go",

        # Workspace directory for go
        $goenv = "C:\goenv",

        # Root directory for consul
        $consulRoot = $goenv + "\consul",

        # The flags that we want set for our wmi_exporter executable
        $wmiFlags = "--collectors.enabled=`"os`"",

        # The version of Consul that we want to download
        $consulVersion = "1.4.0",

        # Where consul is downloaded from 
        $consulURL = "https://releases.hashicorp.com/consul/" + $consulVersion + "/consul_" + $consulVersion + "_windows_amd64.zip",

        # Whatever datacenter we want our host to join in on
        $consulDataCenter = "datacenter",

        # Whatever the fqdn of our consul server is (ie consul.company.com)
        $consulServer = "consul.company.com",

        $consulToken = "x-x-x-x-x",

        # Whatever would come after your hostname making it a fqdn
        $currentDomain = ".company.com",

        # Name of the host we will be installing it on.  Will allow us to use this script in a loop
        $hostname

    )

    # For logging purposes 
    $global:VerbosePreference = "Continue"

    # Because we are going to be modifying system variables we will need to break this up into script block sections
    # When we use Invoke-Command we start a new powershell session which refreshes the system variables
    # This allows the system variables that we set in the go install section to be used by the remaining steps

    ### Installing Go ###
    $goInstall = {
        param ( 
            $downloadDirectory,
            $goVersion,
            $goURL,
            $goRoot,
            $goenv,
            $consulRoot,
            $wmiFlags,
            $consulVersion,
            $consulURL,
            $consulDataCenter,
            $consulServer,
            $consulToken,
            $currentDomain
        ) 
        # First thing we check is if go is already installed
        if(Test-Path "C:\Go\bin\go.exe"){            
            if(go version){
                # Confirmed
                exit
            } else {
                # ERROR: Go appears to be installed but can not confirm.  Please investigate
                exit 
            }
        }

        # Grabbing the executable
        $filepath = Join-Path $downloadDirectory $("go" + $goVersion + ".windows-amd64.zip")
        $grabber = New-Object System.Net.WebClient
        $grabber.DownloadFile($goURL,$filepath)

        # Extracting zip file
        Expand-Archive -Path $filepath -DestinationPath $downloadDirectory -Force

        # Moving extracted files to the root of the C drive
        $gofolder = Join-Path $downloadDirectory $("go")
        Move-Item -Path $gofolder -Destination $goRoot

        # Setting the environmental variables
        [System.Environment]::SetEnvironmentVariable("GOROOT",$goRoot,"Machine")
        $currentPath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
        $newPath = "$goRoot\bin;$currentPath"
        [System.Environment]::SetEnvironmentVariable("PATH", "$newPath", "Machine")
    
        # Making sure our workspace is setup properly
        New-Item -ItemType Directory -Path $goenv
        Set-Location $goenv
        New-Item -ItemType Directory -Name src
        [System.Environment]::SetEnvironmentVariable("GOPATH",$goenv,"User")
    }

    ### Setting up wmi_exporter as a service ###
    $wmieSetup = {
        param ( 
            $downloadDirectory,
            $goVersion,
            $goURL,
            $goRoot,
            $goenv,
            $consulRoot,
            $wmiFlags,
            $consulVersion,
            $consulURL,
            $consulDataCenter,
            $consulServer,
            $consulToken,
            $currentDomain,
            $hostname
        )
    
        # Gitting all the files needed 
        Set-Location $env:GOPATH
        go get -u github.com/golang/dep
        go get -u github.com/prometheus/promu
        go get -u github.com/martinlindhe/wmi_exporter

        # Building the executables
        Set-Location $env:GOPATH/src/github.com/prometheus/promu
        go build
        Set-Location $env:GOPATH/src/github.com/martinlindhe/wmi_exporter
        go build

        # Making the executables into services
        $servicePath = $env:GOPATH + "/src/github.com/martinlindhe/wmi_exporter/wmi_exporter.exe " + $wmiFlags
        New-Service -Name "WMI_Exporter" -BinaryPathName $servicePath -StartupType Automatic -Description "wmi exporter service for consul"
        Start-Service -Name "WMI_Exporter"
        Sleep 3
    }

    ### Setting up consul as a service ###
    $consulSetup = {
        param ( 
            $downloadDirectory,
            $goVersion,
            $goURL,
            $goRoot,
            $goenv,
            $consulRoot,
            $wmiFlags,
            $consulVersion,
            $consulURL,
            $consulDataCenter,
            $consulServer,
            $consulToken,
            $currentDomain,
            $hostname
        )

        # Temp change to make it so that we can download our consul executable
        $securityBackup = [Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls, Ssl3"

        New-Item -ItemType Directory -Path $consulRoot

        ### Modify this based on how you pass in hostnames ###
        $FQDName = $hostname.Split(".")[0] + $currentDomain
    
        # First we grab the executable the same way we did with go
        $filepath = Join-Path $downloadDirectory $("consul_" + $consulVersion + "_windows_amd64.zip")       
        $grabber = New-Object System.Net.WebClient
        $grabber.DownloadFile($consulURL,$filepath)

        # Restoring back to original values
        [Net.ServicePointManager]::SecurityProtocol = $securityBackup

        # Extracting zip file and since it is a single executable we send it straight to where we want it
        Expand-Archive -Path $filepath -DestinationPath $consulRoot -Force

        # Now we need to setup our three json files

        # Getting the current host's IP
        $hostIP = (
            Get-NetIPConfiguration |
                Where-Object {
                    $_.IPv4DefaultGateway -ne $null -and
                    $_.NetAdapter.Status -ne "Disconnected"
                }
        ).IPv4Address.IPAddress
        # In case we are dealing with a host that does not have the Get-NetIPConfiguration command (ie windows 7)
        if(-not $hostIP){
            $hostIP = (Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object {$_.Ipaddress.length -gt 1}).Ipaddress[0]
        }
        if(-not $HostIP){
            $hostIP = Read-Host -Prompt "Enter $hostname IP please: "
        } 

        # We have to escape all our backslashes with backslashes
        $dataDir = $consulRoot.Replace("\","\\")
    
        # The First json file is config.json         
        $configjson = "
        {
	        `"advertise_addr`":`"$hostIP`",
	        `"data_dir`":`"$dataDir`",
	        `"datacenter`":`"$consulDataCenter`",
	        `"leave_on_terminate`":false,
	        `"log_level`":`"ERR`",
	        `"node_name`":`"$FQDName`",
	        `"retry_join`":[`"$consulServer`"]
        }
        "


        # Next we have our client_auth json
        $clientauthjson = "
        {
            `"acl_datacenter`": `"$consulDataCenter`",
            `"acl_down_policy`": `"extend-cache`",
            `"acl_agent_token`": `"$consulToken`",
            `"acl_token`": `"$consulToken`"
        }
        "
        # Lastly we setup our service exporter that tells consul to look for our previously setup wmi_exporter service
        $serviceexport = "
    	    {
		    `"service`":{
			    `"address`":null,
			    `"checks`":[],
			    `"enable_tag_override`":false,
			    `"id`":`"wmi_exporter`",
			    `"name`":`"wmi_exporter`",
			    `"port`":9182,
			    `"tags`":[],
			    `"token`":null
		    }
	    }
        "
        # Now that they are formatted we can write them to file
        Set-Content -Path "$consulRoot\config.json" -Value $configjson 
        Set-Content -Path "$consulRoot\client_auth.json" -Value $clientauthjson
        Set-Content -Path "$consulRoot\service_node_exporter.json" -Value $serviceexport   

        # Lastly we create the service and start it giving it a couple of seconds to get turned on
        $servicePath = $consulRoot + "\consul.exe agent -config-dir $consulRoot"
        New-Service -Name "consul" -BinaryPathName $servicePath -StartupType Automatic -Description "consul agent"
        Start-Service -Name "consul" 
        Sleep 3
    }
    
    # Installs Go
    Invoke-Command -ComputerName $hostname -ScriptBlock $goInstall -ArgumentList $downloadDirectory,$goVersion,$goURL,$goRoot,$goenv,$consulRoot,$wmiFlags,$consulVersion,$consulURL,$consulDataCenter,$consulServer,$consulToken,$currentDomain,$hostname

    # Configures wmi_exporter as a service
    Invoke-Command -ComputerName $hostname -ScriptBlock $wmieSetup -ArgumentList $downloadDirectory,$goVersion,$goURL,$goRoot,$goenv,$consulRoot,$wmiFlags,$consulVersion,$consulURL,$consulDataCenter,$consulServer,$consulToken,$currentDomain,$hostname

    # Configures consul as a service
    Invoke-Command -ComputerName $hostname -ScriptBlock $consulSetup -ArgumentList $downloadDirectory,$goVersion,$goURL,$goRoot,$goenv,$consulRoot,$wmiFlags,$consulVersion,$consulURL,$consulDataCenter,$consulServer,$consulToken,$currentDomain,$hostname

}


Install-CosnulWithWMIExporter -hostname ""
