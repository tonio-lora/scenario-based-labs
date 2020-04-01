#################
#
# Run to get the lasest AZ powershell commands (for stream analytics) NOTE:  Not all stream analytics components can be auto deployed
#
#################
#Install-Module -Name Az -AllowClobber -Scope CurrentUser
#################
$githubPath = "YOUR GIT PATH";

#can be 'lab' or 'demo'
$mode = "demo"

#if you want to use a specific subscription
$subscriptionId = "YOUR SUB ID"

#create a unique resource group name
$prefix = "YOUR INIT"

#used for when you are using spektra environment
$isSpektra = $false;

if ($isSpektra)
{
    #if you are using spektra...you have to set your resource group here:
    $rgName = read-host "What is your spektra resource group name?";
}
else
{
    $rgName = $prefix + "_s2_retail"
}

#used for cosmos db
$databaseId = "movies";

#FYI - not all regions have been tested - 
#Check your region support here : https://azure.microsoft.com/en-us/global-infrastructure/services/?products=
#for a list of regions run : az account list-locations -o table
#OK - westus, eastus, northeurope
$region = "northeurope";

#register at https://api.themoviedb.org
$movieApiKey = "YOUR API KEY";

#toggles for skipping items
$skipDeployment = $false;

#this should get set on a successful deployment...
$suffix = ""

#Implicit Key Vault usage
$useKeyVault = $false

###################################
#
#  Functions
#
###################################

function SetKeyVaultValue($kvName, $name, $value)
{
    if ($value)
    {
        write-host "Setting $name to $value";

        $res = $(az keyvault secret set --vault-name $kvName --name $name --value $value);    
    }

    return $res;
}

function DownloadNuget()
{
    $sourceNugetExe = "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe"
    $targetNugetExe = "$githubPath\nuget.exe"
    Invoke-WebRequest $sourceNugetExe -OutFile $targetNugetExe
    Set-Alias nuget $targetNugetExe -Scope Global -Verbose
}

function BuildVS
{
    param
    (
        [parameter(Mandatory=$true)]
        [String] $path,

        [parameter(Mandatory=$false)]
        [bool] $nuget = $true,
        
        [parameter(Mandatory=$false)]
        [bool] $clean = $true
    )
    process
    {
        #install nuget...
        DownloadNuget

        #default
        $msBuildExe = 'C:\Program Files (x86)\MSBuild\14.0\Bin\msbuild.exe'

        $msBuild = "msbuild"

        try
        {
            & $msBuild /version
            Write-Host "Likely on Linux/macOS."
        }
        catch
        {
            Write-Host "MSBuild doesn't exist. Use VSSetup instead."
            
            Install-Module VSSetup -Scope CurrentUser -Force
            
            $instance = Get-VSSetupInstance -All -Prerelease | Select-VSSetupInstance -Require 'Microsoft.Component.MSBuild' -Latest
            $installDir = $instance.installationPath

            Write-Host "Visual Studio is found at $installDir"
            
            $msBuildExe = $installDir + '\MSBuild\Current\Bin\MSBuild.exe' # VS2019
            
            if (![System.IO.File]::Exists($msBuildExe))
            {
                $msBuild = $installDir + '\MSBuild\15.0\Bin\MSBuild.exe' # VS2017

                if (![System.IO.File]::Exists($msBuildExe))
                {
                    Write-Host "MSBuild doesn't exist. Exit."
                    exit 1
                }

            }    Write-Host "Likely on Windows."
        }Write-Host "MSBuild found. Compile the projects."

        if ($nuget) {
            Write-Host "Restoring NuGet packages" -foregroundcolor green
            nuget restore "$($path)"
        }

        if ($clean) {
            Write-Host "Cleaning $($path)" -foregroundcolor green
            & "$($msBuildExe)" "$($path)" /t:Clean /m
        }

        Write-Host "Building $($path)" -foregroundcolor green
        & "$($msBuildExe)" "$($path)" /t:Build /m
    }
}

function DeployTemplate($filename, $skipDeployment, $parameters, $name)
{
    write-host "Deploying [$filename] - Please wait";

    if (!$skipDeployment)
    {
        if ($name)
        {
            $deployid = $name;
        }
        else
        {
            #deploy the template
            $deployId = [System.Guid]::NewGuid().ToString();
        }

        Remove-Item "parameters.json" -ea SilentlyContinue;
        add-content "parameters.json" $parameters;

        if (!$parameters)
        {
            $result = $(az deployment group create --name $deployId --resource-group $rgName --mode Incremental --template-file $($githubpath + "\retail-2020\deploy\$fileName") --output json)
        }
        else
        {
            $result = $(az deployment group create --name $deployId --resource-group $rgName --mode Incremental --template-file $($githubpath + "\retail-2020\deploy\$fileName") --output json --parameters `@$githubpath\parameters.json)
        }
        

        #wait for the job to complete...
        $res = $(az deployment group list --resource-group $rgname --output json)
        $json = ConvertObjectToJson $res;

        $deployment = $json | where {$_.name -eq $deployId};

        #check the status
        while($deployment.properties.provisioningState -eq "Running")
        {
            start-sleep 10;

            $res = $(az deployment group list --resource-group $rgname --output json)
            $json = ConvertObjectToJson $res;

            $deployment = $json | where {$_.name -eq $deployId};

            write-host "Deployment status is : $($deployment.properties.provisioningState)";
        }

        Remove-Item "parameters.json" -ea SilentlyContinue;

        write-host "Deploying [$fileName] finished with status $($deployment.properties.provisioningState)";
    }

    return $deployment;
}

function UpdateConfig($path)
{
    [xml]$xml = get-content $filepath;

    #set the function url
    $data = $xml.configuration.appSettings.add | where {$_.key -eq "funcAPIUrl"}

    if($data)
    {
        $data.value = $funcApiUrl;
    }

    #set the database url
    $data = $xml.configuration.appSettings.add | where {$_.key -eq "dbConnectionUrl"}

    if($data)
    {
        $data.value = $dbConnectionUrl;
    }

    #set the database key
    $data = $xml.configuration.appSettings.add | where {$_.key -eq "dbConnectionKey"}

    if($data)
    {
        $data.value = $dbConnectionKey;
    }

    #set the movie api key
    $data = $xml.configuration.appSettings.add | where {$_.key -eq "movieApiKey"}

    if($data)
    {
        $data.value = $movieApiKey;
    }

    #set the database id
    $data = $xml.configuration.appSettings.add | where {$_.key -eq "databaseId"}

    if($data)
    {
        $data.value = $databaseId;
    }

    $xml.save($filePath);    
}

function Output()
{
    write-host "Output variables:"

    write-host "Azure Queue: $azurequeueConnString"
    write-host "Func Url: $funcApiUrl"
    write-host "Cosmos DB Url: $dbConnectionUrl"
    write-host "Cosmos DB Key: $dbConnectionKey"
    write-host "DatabaseId: $databaseId"
    write-host "EventHubConn: $eventHubConnection"
    write-host "CosmosDBFull: $CosmosDBConnection"
    write-host "AzureKeyVault: $keyvaulturl"
    write-host "Email: $userEmail"
}

function SetupStreamAnalytics($suffix)
{
    #deploy the template
    $deployId = "Microsoft.Template"
    $result = $(az deployment group create --name $deployId --resource-group $rgName --mode Incremental --template-file $($githubpath + "\retail-2020\deploy\labdeploy2.json") --output json )

    #wait for the job to complete...
    $res = $(az deployment group list --resource-group $rgname --output json)
    $json = ConvertObjectToJson $res;

    $deployment = $json | where {$_.name -eq $deployId};

    #https://docs.microsoft.com/en-us/azure/stream-analytics/stream-analytics-quick-create-powershell
    Connect-AzAccount -Subscription $subName

    $jobName = "s2_analytics_$suffix";

    #set the stream analytics inputs - TODO needs sharedaccesspolicykey...
    $jobInputName = "s2event"
    $jobInputDefinitionFile = "streamanaltyics_input_1.json"

    New-AzStreamAnalyticsInput -ResourceGroupName $rgName -JobName $jobName -File $jobInputDefinitionFile -Name $jobInputName;

    #set the stream analytics outputs (#1)
    $jobOutputName = "eventCount"
    $jobOutputDefinitionFile = "streamanaltyics_output_1.json"

    New-AzStreamAnalyticsOutput -ResourceGroupName $rgName -JobName $jobName -File $jobOutputDefinitionFile -Name $jobOutputName -Force

    #set the stream analytics outputs (#2)
    $jobOutputName = "eventOrdersLastHour"
    $jobOutputDefinitionFile = "streamanaltyics_output_2.json"

    New-AzStreamAnalyticsOutput -ResourceGroupName $rgName -JobName $jobName -File $jobOutputDefinitionFile -Name $jobOutputName -Force

    #set the stream analytics outputs (#3)
    $jobOutputName = "eventSummary"
    $jobOutputDefinitionFile = "streamanaltyics_output_3.json"

    New-AzStreamAnalyticsOutput -ResourceGroupName $rgName -JobName $jobName -File $jobOutputDefinitionFile -Name $jobOutputName -Force

    #set the stream analytics outputs (#4)
    $jobOutputName = "failureCount"
    $jobOutputDefinitionFile = "streamanaltyics_output_4.json"

    New-AzStreamAnalyticsOutput -ResourceGroupName $rgName -JobName $jobName -File $jobOutputDefinitionFile -Name $jobOutputName -Force

    #set the stream analytics outputs (#5)
    $jobOutputName = "userCount"
    $jobOutputDefinitionFile = "streamanaltyics_output_5.json"

    New-AzStreamAnalyticsOutput -ResourceGroupName $rgName -JobName $jobName -File $jobOutputDefinitionFile -Name $jobOutputName -Force

    #set the stream analytics query
    $jobTransformationName = "s2_retail_job"
    $jobTransformationDefinitionFile = "streamanaltyics_query.json"

    New-AzStreamAnalyticsTransformation -ResourceGroupName $rgName -JobName $jobName -File $jobTransformationDefinitionFile -Name $jobTransformationName -Force

    #start the job
    Start-AzStreamAnalyticsJob -ResourceGroupName $rgName -Name $jobName -OutputStartMode 'JobStartTime'
}

function ConvertObject($data)
{
    $str = "";
    foreach($c in $data)
    {
        $str += $c;
    }

    return $str;
}

function ConvertObjectToJson($data)
{
    $json = ConvertObject $data;

    return ConvertFrom-json $json;
}

###################################
#
#  Main
#
###################################

cd $githubpath

#login - do this always as AAD will error if you change location/ip
$res = az login;
$json = ConvertObjectToJson $res;

#help out with the email address...
$userEmail = $json[0].user.name;

$res = az ad user show --upn-or-object-id $userEmail
$json = ConvertObjectToJson $res

#get object id for current user to assign to key vault
$userObjectId = $json.objectId;

#select the subscription if you set it
if ($subscriptionId)
{
    $res = az account set --subscription $subscriptionId;
}

$res = $(az account show)
$json = ConvertObjectToJson $res

$tenantId = $json.tenantId;

#create the resource group (if not in spektra)
if (!$isSpektra)
{
    $res = az group create --name $rgName --location $region;
}

$parametersRegion = @{
            "schema"="http://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#"
            "contentVersion"="1.0.0.0"
            "parameters"=@{
                 "region"=@{"value"="$region"}
                 }
            } | ConvertTo-Json

$parameters = @{
            "schema"="http://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#"
            "contentVersion"="1.0.0.0"
            "parameters"=@{
                 "region"=@{"value"="$region"}
                 "msiId"=@{"value"="TBD"}
                 "prefix"=@{"value"="$prefix"}
                 "tenantId"=@{"value"="$tenantId"}
                 "userObjectId"=@{"value"="$userObjectId"}
                 }
            } | ConvertTo-Json
            
$deployment = DeployTemplate "labdeploy_main.json" $skipDeployment $parameters "01_Main";

#need the suffix...
if ($deployment.properties.provisioningState -eq "Succeeded")
{
    $suffix = $deployment.properties.outputs.hash.value
}

if (!$suffix)
{
    $suffix = read-host "Deployment failed: Please enter the suffix that was created for the resource group";

    if (!$suffix)
    {
        write-host "No suffix, stopping";
        return;
    }
}

$parameters = @{
            "schema"="http://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#"
            "contentVersion"="1.0.0.0"
            "parameters"=@{
                 "region"=@{"value"="$region"}
                 "msiId"=@{"value"="TBD"}
                 "prefix"=@{"value"="$prefix"}
                 "tenantId"=@{"value"="$tenantId"}
                 "userObjectId"=@{"value"="$userObjectId"}
                 }
            } | ConvertTo-Json

#deploy containers - this is ok to fail
$deployment = DeployTemplate "labdeploy_cosmos.json" $skipDeployment $parametersRegion "02_CosmosContainers";

#get all the resources in the RG
$res = $(az resource list --resource-group $rgName)
$json = ConvertObjectToJson $res;

#stream analytics will overwrite settings if deployed more than once!
$saJob = $json | where {$_.type -eq "Microsoft.StreamAnalytics/streamingjobs"};

if (!$saJob)
{
    #deploy stream analytics
    $deployment = DeployTemplate "labdeploy_streamanalytics.json" $skipDeployment $parametersRegion "03_StreamAnalytics";
}

#LOGIC APPS will overwrite settings if deployed more than once!
$logicApp = $json | where {$_.type -eq "Microsoft.Logic/workflows"};

if (!$logicApp)
{
    #deploy logic app
    $deployment = DeployTemplate "labdeploy_logicapp.json" $skipDeployment $parametersRegion "04_LogicApp";
}

#used later (databricks)
$databricksName = "s2databricks" + $suffix;
$databricks = $json | where {$_.type -eq "Microsoft.Databricks/workspaces" -and $_.name -eq $databricksName};

#used later (keyvault)
$keyvaultName = "s2keyvault" + $suffix;
$keyvault = $json | where {$_.type -eq "Microsoft.KeyVault/vaults" -and $_.name -eq $keyvaultName};

#used later (function app)
$funcAppName = "s2func" + $suffix;
$funcApp = $json | where {$_.type -eq "Microsoft.Web/sites" -and $_.name -eq $funcAppName};

#used later (web app)
$webAppName = "s2web" + $suffix;
$webApp = $json | where {$_.type -eq "Microsoft.Web/sites" -and $_.name -eq $webAppName};

#get all the settings
$azurequeueConnString = "";
$paymentsApiUrl = "";
$funcApiUrl = "";
$dbConnectionUrl = "";
$dbConnectionKey = "";
$databaseId = "movies"
$eventHubConnection = "";
$CosmosDBConnection = "";

########################
#
#get key vault url
#
########################

$keyVaulturl = "https://$($keyvault.Name).vault.azure.net";

########################
#
#get the event hub connection
#
########################
write-host "Getting event hub connection"

$res = $(az eventhubs namespace list --output json --resource-group $rgName)
$json = ConvertObjectToJson $res;

$sa = $json | where {$_.name -eq "s2ns" + $suffix};
$res = $(az eventhubs namespace authorization-rule keys list --resource-group $rgName --namespace-name $sa.name --name RootManageSharedAccessKey)
$json = ConvertObjectToJson $res;

$eventHubConnection = $json.primaryConnectionString

########################
#
#get the storage connection string
#
########################
write-host "Getting storage account key"

$res = $(az storage account list --output json --resource-group $rgName)
$json = ConvertObjectToJson $res;

$sa = $json | where {$_.name -eq "s2data3" + $suffix};

$res = $(az storage account keys list --account-name $sa.name)
$json = ConvertObjectToJson $res;

$key = $json[0].value;

$azurequeueConnString = "DefaultEndpointsProtocol=https;AccountName=$($sa.name);AccountKey=$($key);EndpointSuffix=core.windows.net";

########################
#
#get the cosmos db url and key
#
#########################
write-host "Getting cosmos db url and key"

$res = $(az cosmosdb list --output json --resource-group $rgName)
$json = ConvertObjectToJson $res;

$db = $json | where {$_.name -eq "s2cosmosdb" + $suffix};

$dbConnectionUrl = $db.documentEndpoint;

$res = $(az cosmosdb keys list --name $db.name --resource-group $rgName)
$json = ConvertObjectToJson $res;

$dbConnectionKey = $json.primaryMasterKey;

$CosmosDBConnection = "AccountEndpoint=$dbConnectionUrl;AccountKey=$dbConnectionKey";

########################
#
#deploy the web app
#
#########################
$webAppName = "s2web" + $suffix;

if ($mode -eq "demo")
{ 
    write-host "Deploying the web application"

    $res = $(az webapp deployment source config-zip --resource-group $rgName --name $webAppName --src "$githubpath/retail-2020/deploy/webapp.zip")
    $json = ConvertObjectToJson $res;
}

########################
#
#deploy the function
#
#########################

$funcAppName = "s2func" + $suffix;

#we have to deploy something in order for the host.json file to be created in the storage account...
if ($mode -eq "demo")
{
    write-host "Deploying the function app"

    $res = $(az functionapp deployment source config-zip --resource-group $rgName --name $funcAppName --src "$githubpath/retail-2020/deploy/functionapp.zip")
    $json = ConvertObjectToJson $res;
}

########################
#
#get the function url
#
#########################
write-host "Getting the function app url and key"

$res = $(az functionapp list --output json --resource-group $rgName)
$json = ConvertObjectToJson $res;

$func = $json | where {$_.name -eq $funcAppName};

$funcApiUrl = "https://" + $func.defaultHostName;

########################
#
# save key vault values
#
#########################

write-host "Setting key vault values..."

$res = SetKeyVaultValue $keyvault.Name "paymentsAPIUrl" $paymentsApiUrl;
$res = SetKeyVaultValue $keyvault.Name "AzureQueueConnectionString" $azurequeueConnString;

$res = SetKeyVaultValue $keyvault.Name "funcApiUrl" $funcApiUrl;
$json = ConvertObjectToJson $res;
$kvFuncApiUrl = "@Microsoft.KeyVault(SecretUri=$($json.id))"

$res = SetKeyVaultValue $keyvault.Name "databaseId" $databaseId;
$json = ConvertObjectToJson $res;
$kvdatabaseId = "@Microsoft.KeyVault(SecretUri=$($json.id))"

$res = SetKeyVaultValue $keyvault.Name "CosmosDBConnection" $CosmosDBConnection;
$json = ConvertObjectToJson $res;
$kvCosmosDBConnection = "@Microsoft.KeyVault(SecretUri=$($json.id))"

$res = SetKeyVaultValue $keyvault.Name "dbConnectionUrl" $dbConnectionUrl;
$json = ConvertObjectToJson $res;
$kvdbConnectionUrl = "@Microsoft.KeyVault(SecretUri=$($json.id))"

$res = SetKeyVaultValue $keyvault.Name "dbConnectionKey" $dbConnectionKey;
$json = ConvertObjectToJson $res;
$kvdbConnectionKey = "@Microsoft.KeyVault(SecretUri=$($json.id))"

$res = SetKeyVaultValue $keyvault.Name "eventHubConnection" $eventHubConnection;
$json = ConvertObjectToJson $res;
$kveventHubConnection = "@Microsoft.KeyVault(SecretUri=$($json.id))"

$res = SetKeyVaultValue $keyvault.Name "eventHub" "store";
$json = ConvertObjectToJson $res;
$kveventHub = "@Microsoft.KeyVault(SecretUri=$($json.id))"

$res = SetKeyVaultValue $keyvault.Name "movieApiKey" $movieApiKey;
$json = ConvertObjectToJson $res;
$kvmovieApiKey = "@Microsoft.KeyVault(SecretUri=$($json.id))"

$res = SetKeyVaultValue $keyvault.Name "LogicAppUrl" "";
$json = ConvertObjectToJson $res;
$kvLogicAppUrl = "@Microsoft.KeyVault(SecretUri=$($json.id))"

$res = SetKeyVaultValue $keyvault.Name "RecipientEmail" $userEmail;
$json = ConvertObjectToJson $res;
$kvRecipientEmail = "@Microsoft.KeyVault(SecretUri=$($json.id))"

########################
#
#set the web app properties
#
#########################
write-host "Saving app settings to web application"

if($useKeyVault)
{
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings AzureQueueConnectionString=$kvazurequeueConnString)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings paymentsAPIUrl=$kvpaymentsApiUrl)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings funcAPIUrl=$kvfuncApiUrl)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings databaseId=$kvdatabaseId)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings dbConnectionUrl=$kvdbConnectionUrl)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings dbConnectionKey=$kvdbConnectionKey)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings movieApiKey=$kvmovieApiKey)
}
else
{
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings AzureQueueConnectionString=$azurequeueConnString)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings paymentsAPIUrl=$paymentsApiUrl)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings funcAPIUrl=$funcApiUrl)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings databaseId=$databaseId)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings dbConnectionUrl=$dbConnectionUrl)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings dbConnectionKey=$dbConnectionKey)
    $res = $(az webapp config appsettings set -g $rgName -n $webAppName --settings movieApiKey=$movieApiKey)
}


########################
#
#set the func properties
#
#########################
write-host "Saving app settings to func app..."

if ($useKeyVault)
{
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings AzureQueueConnectionString=$kvazurequeueConnString)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings paymentsAPIUrl=bl$kvpaymentsApiUrlah)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings funcAPIUrl=$kvfuncApiUrl)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings databaseId=$kvdatabaseId)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings CosmosDBConnection=$kvCosmosDBConnection)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings dbConnectionUrl=$kvdbConnectionUrl)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings dbConnectionKey=$kvdbConnectionKey)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings eventHubConnection=$kveventHubConnection)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings eventHub=store)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings movieApiKey=$kvmovieApiKey)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings LogicAppUrl=empty)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings RecipientEmail=$kvuserEmail)
}
else
{
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings AzureQueueConnectionString=$azurequeueConnString)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings paymentsAPIUrl=bl$paymentsApiUrlah)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings funcAPIUrl=$funcApiUrl)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings databaseId=$databaseId)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings CosmosDBConnection=$CosmosDBConnection)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings dbConnectionUrl=$dbConnectionUrl)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings dbConnectionKey=$dbConnectionKey)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings eventHubConnection=$eventHubConnection)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings eventHub=store)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings movieApiKey=$movieApiKey)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings LogicAppUrl=empty)
    $res = $(az webapp config appsettings set -g $rgName -n $funcAppName --settings RecipientEmail=$userEmail)
}

########################
#
#compile the project
#
########################
if ($mode -eq "demo")
{
    write-host "Compiling the projects..."

    BuildVS "$githubPath\Retail-2020\Solution\Data Import\MovieDataImport.sln" $true $true
    BuildVS "$githubPath\Retail-2020\Solution\DataGenerator\DataGenerator.sln" $true $true
    BuildVS "$githubPath\Retail-2020\Solution\Contoso Movies\Contoso.Apps.Movies.sln" $true $true
}


########################
#
#Update project configs to be nice ;)
#
########################
write-host "Saving app settings to Visual Studio solutions (starter and solution)"

$folders = ("starter", "solution")

foreach($folder in $folders)
{
    $filePath = "$githubpath\Retail-2020\$folder\Data Import\app.config"
    UpdateConfig $filePath;

    $filePath = "$githubpath\Retail-2020\$folder\DataGenerator\app.config"
    UpdateConfig $filePath;

    $filePath = "$githubpath\Retail-2020\$folder\Contoso Movies\Contoso.Apps.Movies.Web\web.config"
    UpdateConfig $filePath;
}

if ($mode -eq "demo")
{ 
    #update the app.config file with the new values
    $filePath = "$githubpath\Retail-2020\Solution\Data Import\bin\Debug\MovieDataImport.exe.config"
    UpdateConfig $filePath;
}

########################
#
# Open the web site
#
########################
if ($mode -eq "demo")
{
    $url = "https://$($webapp.name).azurewebsites.net";
    write-host "Opening url: $url";
    Start-Process $url;
}

########################
#
#deploy stream analytics - Not production ready - does not support Power BI Outputs
#
#########################
#SetupStreamAnalytics $suffix;

########################
#
# Output variables
#
########################
Output