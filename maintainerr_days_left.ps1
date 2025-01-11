# Define your Plex server and Maintainerr details
$PLEX_URL = $env:PLEX_URL
$PLEX_TOKEN = $env:PLEX_TOKEN
$MAINTAINERR_URL = $env:MAINTAINERR_URL
$IMAGE_SAVE_PATH = $env:IMAGE_SAVE_PATH
$ORIGINAL_IMAGE_PATH = $env:ORIGINAL_IMAGE_PATH
$TEMP_IMAGE_PATH = $env:TEMP_IMAGE_PATH
$FONT_PATH = $env:FONT_PATH
$FONT_COLOR = $env:FONT_COLOR
$BACK_COLOR = $env:BACK_COLOR
$FONT_SIZE = [int]$env:FONT_SIZE
$PADDING = [int]$env:PADDING
$BACK_RADIUS = [int]$env:BACK_RADIUS
$HORIZONTAL_OFFSET = [int]$env:HORIZONTAL_OFFSET
$HORIZONTAL_ALIGN = $env:HORIZONTAL_ALIGN
$VERTICAL_OFFSET = [int]$env:VERTICAL_OFFSET
$VERTICAL_ALIGN = $env:VERTICAL_ALIGN
$RUN_INTERVAL = [int]$env:RUN_INTERVAL

if (-not $RUN_INTERVAL) {
    $RUN_INTERVAL = 8 * 60 * 60 # Default to 8 hours in seconds
} else {
    $RUN_INTERVAL = $RUN_INTERVAL * 60 # Convert minutes to seconds
}

# Define path for tracking collection state
$CollectionStateFile = "$IMAGE_SAVE_PATH/current_collection_state.json"

# Initialize collection state if the file does not exist
if (-not (Test-Path -Path $CollectionStateFile)) {
    @{} | ConvertTo-Json | Set-Content -Path $CollectionStateFile
}

function Load-CollectionState {
    if (Test-Path -Path $CollectionStateFile) {
        try {
            $rawContent = Get-Content -Path $CollectionStateFile -Raw
            Write-Host "Raw State File Content: $rawContent"

            # Enforce parsing into a valid object
            $state = $rawContent | ConvertFrom-Json -Depth 10

            if ($state -eq $null) {
                Write-Host "Warning: Parsed state is null. Initializing as empty."
                return @{}
            }

            if ($state -is [PSCustomObject]) {
                return $state.PSObject.Properties | ForEach-Object { @{ $_.Name = $_.Value } }
            }

            return $state
        } catch {
            Write-Warning "Failed to load or parse state file: $_. Initializing as empty."
            return @{}
        }
    } else {
        Write-Host "State file does not exist. Initializing as empty."
        return @{}
    }
}

function Save-CollectionState {
    param (
        [hashtable]$state
    )
    $stringKeyedState = @{}
    foreach ($key in $state.Keys) {
        $stringKeyedState["$key"] = $state[$key]
    }
    try {
        $stringKeyedState | ConvertTo-Json -Depth 10 | Set-Content -Path $CollectionStateFile
        Write-Host "Successfully saved state: $(ConvertTo-Json $stringKeyedState -Depth 10)"
    } catch {
        Write-Error "Failed to save state: $_"
    }
}


# Function to get data from Maintainerr
function Get-MaintainerrData {
    $response = Invoke-RestMethod -Uri $MAINTAINERR_URL -Method Get
    return $response
}

# Function to calculate the calendar date
function Calculate-Date {
    param (
        [Parameter(Mandatory=$true)]
        [datetime]$addDate,

        [Parameter(Mandatory=$true)]
        [int]$deleteAfterDays
    )

    $deleteDate = $addDate.AddDays($deleteAfterDays)
    $daySuffix = switch ($deleteDate.Day) {
        1  { "st" }
        2  { "nd" }
        3  { "rd" }
        21 { "st" }
        22 { "nd" }
        23 { "rd" }
        31 { "st" }
        default { "th" }
    }
    $formattedDate = $deleteDate.ToString("MMM d") + $daySuffix
    return $formattedDate
}

function Download-Poster {
    param (
        [string]$posterUrl,
        [string]$savePath
    )
    try {
        # Check if the file exists and meets minimum size requirements
        if (-not (Test-Path -Path $savePath) -or (Get-Item -Path $savePath).Length -lt 1024) {
            Write-Host "Downloading poster from: $posterUrl to: $savePath"

            # Attempt to download the poster
            Invoke-WebRequest -Uri $posterUrl -OutFile $savePath -Headers @{"X-Plex-Token"=$PLEX_TOKEN}

            # Validate the downloaded file
            if (-not (Test-Path -Path $savePath) -or (Get-Item -Path $savePath).Length -lt 1024) {
                throw "Poster download failed or file is too small."
            }

            # Optionally, validate the file as an image
            if (-not (Validate-Poster -filePath $savePath)) {
                Write-Warning "Downloaded file at $savePath is not a valid image. Deleting file."
                Remove-Item -Path $savePath -Force
                throw "Invalid poster file format detected."
            }

            Write-Host "Successfully downloaded poster to: $savePath"
        } else {
            Write-Host "Poster already exists and meets size requirements at: $savePath"
        }
    } catch {
        Write-Warning "Failed to download poster from $posterUrl to $savePath. Error: $_"
        throw
    }
}

# Function to revert to the original poster
function Revert-ToOriginalPoster {
    param (
        [string]$plexId,
        [string]$originalImagePath
    )

    if (-not (Test-Path -Path $originalImagePath)) {
        Write-Warning "Original image not found for Plex ID: $plexId. Skipping revert."
        return
    }

    Write-Host "Reverting Plex ID: $plexId to original poster."
    $uploadUrl = "$PLEX_URL/library/metadata/$plexId/posters?X-Plex-Token=$PLEX_TOKEN"
    $posterBytes = [System.IO.File]::ReadAllBytes($originalImagePath)
    Invoke-RestMethod -Uri $uploadUrl -Method Post -Body $posterBytes -ContentType "image/jpeg"
}

# Function to add overlay text to the poster
function Add-Overlay {
    param (
        [string]$imagePath,
        [string]$text,
        [string]$fontColor = $FONT_COLOR,
        [string]$backColor = $BACK_COLOR,
        [string]$fontPath = $FONT_PATH,
        [int]$fontSize = $FONT_SIZE,
        [int]$padding = $PADDING,
        [int]$backRadius = $BACK_RADIUS,
        [int]$horizontalOffset = $HORIZONTAL_OFFSET,
        [string]$horizontalAlign = $HORIZONTAL_ALIGN,
        [int]$verticalOffset = $VERTICAL_OFFSET,
        [string]$verticalAlign = $VERTICAL_ALIGN
    )

    Add-Type -AssemblyName System.Drawing

    $image = [System.Drawing.Image]::FromFile($imagePath)
    $graphics = [System.Drawing.Graphics]::FromImage($image)

    $imageWidth = $image.Width
    $imageHeight = $image.Height

    $scaleFactor = $imageWidth / 1000  # Reference width of 1000px
    $scaledFontSize = [int]($fontSize * $scaleFactor)
    $scaledPadding = [int]($padding * $scaleFactor)
    $scaledBackRadius = [int]($backRadius * $scaleFactor)
    $scaledHorizontalOffset = [int]($horizontalOffset * $scaleFactor)
    $scaledVerticalOffset = [int]($verticalOffset * $scaleFactor)

    $privateFontCollection = New-Object System.Drawing.Text.PrivateFontCollection
    $privateFontCollection.AddFontFile($fontPath)
    $fontFamily = $privateFontCollection.Families[0]
    $font = New-Object System.Drawing.Font($fontFamily, $scaledFontSize, [System.Drawing.FontStyle]::Bold)

    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($fontColor))
    $backBrush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($backColor))

    $size = $graphics.MeasureString($text, $font)

    $backWidth = [int]($size.Width + $scaledPadding * 2)
    $backHeight = [int]($size.Height + $scaledPadding * 2)

    switch ($horizontalAlign) {
        "right" { $x = $image.Width - $backWidth - $scaledHorizontalOffset }
        "center" { $x = ($image.Width - $backWidth) / 2 }
        "left" { $x = $scaledHorizontalOffset }
        default { $x = $image.Width - $backWidth - $scaledHorizontalOffset }
    }

    switch ($verticalAlign) {
        "bottom" { $y = $image.Height - $backHeight - $scaledVerticalOffset }
        "center" { $y = ($image.Height - $backHeight) / 2 }
        "top" { $y = $scaledVerticalOffset }
        default { $y = $image.Height - $backHeight - $scaledVerticalOffset }
    }

    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($x, $y, $scaledBackRadius, $scaledBackRadius, 180, 90)
    $path.AddArc($x + $backWidth - $scaledBackRadius, $y, $scaledBackRadius, $scaledBackRadius, 270, 90)
    $path.AddArc($x + $backWidth - $scaledBackRadius, $y + $backHeight - $scaledBackRadius, $scaledBackRadius, $scaledBackRadius, 0, 90)
    $path.AddArc($x, $y + $backHeight - $scaledBackRadius, $scaledBackRadius, $scaledBackRadius, 90, 90)
    $path.CloseFigure()
    $graphics.FillPath($backBrush, $path)

    $textX = $x + ($backWidth - $size.Width) / 2
    $textY = $y + ($backHeight - $size.Height) / 2

    $graphics.DrawString($text, $font, $brush, $textX, $textY)

    $outputImagePath = [System.IO.Path]::Combine($TEMP_IMAGE_PATH, [System.IO.Path]::GetFileName($imagePath))

    try {
        $image.Save($outputImagePath)
    } catch {
        Write-Error "Failed to save image: $_"
    } finally {
        $graphics.Dispose()
        $image.Dispose()
    }
    return $outputImagePath
}

# Function to upload the modified poster back to Plex
function Upload-Poster {
    param (
        [string]$posterPath,
        [string]$metadataId
    )
    $uploadUrl = "$PLEX_URL/library/metadata/$metadataId/posters?X-Plex-Token=$PLEX_TOKEN"
    $posterBytes = [System.IO.File]::ReadAllBytes($posterPath)
    Invoke-RestMethod -Uri $uploadUrl -Method Post -Body $posterBytes -ContentType "image/jpeg"

    try {
        Remove-Item -Path $posterPath -ErrorAction Stop
        Write-Host "Deleted temporary file: $posterPath"
    } catch {
        Write-Error "Failed to delete temporary file ${posterPath}: $_"
    }
}

function Validate-Poster {
    param (
        [string]$filePath
    )
    try {
        Add-Type -AssemblyName System.Drawing
        $image = [System.Drawing.Image]::FromFile($filePath)
        $image.Dispose()
        return $true
    } catch {
        Write-Warning "File at $filePath is not a valid image. Error: $_"
        return $false
    }
}


# Function to perform janitorial tasks: revert and delete unused posters
function Janitor-Posters {
    param (
        [array]$mediaList,          # List of current Plex media GUIDs
        [array]$maintainerrGUIDs,   # List of GUIDs in the Maintainerr collection
        [hashtable]$newState,       # Current valid state from Process-MediaItems
        [string]$originalImagePath, # Path to original poster images
        [string]$collectionName     # Name of the collection for context/logging
    )

    Write-Host "Running janitorial logic for collection: $collectionName"

    # Gather all downloaded posters
    $downloadedPosters = Get-ChildItem -Path $originalImagePath -Filter "*.jpg" | ForEach-Object { $_.BaseName }

    # GUIDs considered valid (in Plex, in Maintainerr, or in newState)
    $validGUIDs = $mediaList + $maintainerrGUIDs + $newState.Keys

    # GUIDs to handle
    $unusedGUIDs = $downloadedPosters | Where-Object { $_ -notin $validGUIDs }
    $revertGUIDs = $downloadedPosters | Where-Object { $_ -in $mediaList -and $_ -notin $maintainerrGUIDs }

    # Revert posters for media still in Plex but no longer in Maintainerr
    foreach ($guid in $revertGUIDs) {
        $posterPath = Join-Path -Path $originalImagePath -ChildPath "$guid.jpg"
        if (Test-Path -Path $posterPath) {
            Write-Host "Reverting poster for GUID: $guid"
            Revert-ToOriginalPoster -plexId $guid -originalImagePath $posterPath
            Remove-Item -Path $posterPath -ErrorAction SilentlyContinue
        } else {
            Write-Warning "No poster file found to revert for GUID: $guid"
        }
    }

    # Delete posters for media removed from Plex or no longer valid
    foreach ($guid in $unusedGUIDs) {
        $posterPath = Join-Path -Path $originalImagePath -ChildPath "$guid.jpg"
        if (Test-Path -Path $posterPath) {
            Write-Host "Deleting unused poster for GUID: $guid"
            Remove-Item -Path $posterPath -ErrorAction SilentlyContinue
        }
    }
}

function Process-MediaItems {
    $maintainerrData = Get-MaintainerrData
    $currentState = Load-CollectionState

    # Initialize new state
    $newState = @{}

    foreach ($collection in $maintainerrData) {
        Write-Host "Processing collection: $($collection.Name)"
        $deleteAfterDays = $collection.deleteAfterDays

        foreach ($item in $collection.media) {
            $plexId = $item.plexId.ToString()
            $originalImagePath = "$ORIGINAL_IMAGE_PATH/$plexId.jpg"
            $tempImagePath = "$TEMP_IMAGE_PATH/$plexId.jpg"
            $posterUrl = "$PLEX_URL/library/metadata/$plexId/thumb?X-Plex-Token=$PLEX_TOKEN"

            # Add media item to new state
            $newState[$plexId] = $true
            Write-Host "Added to newState: Plex ID = $plexId, State = true"

            try {
                # Ensure the original poster is downloaded first
                if (-not (Test-Path -Path $originalImagePath)) {
                    Write-Host "Original poster not found for Plex ID: $plexId. Downloading..."
                    Download-Poster -posterUrl $posterUrl -savePath $originalImagePath

                    # Verify if the poster was successfully downloaded
                    if (-not (Test-Path -Path $originalImagePath)) {
                        throw "Failed to download original poster for Plex ID: $plexId"
                    }
                } else {
                    Write-Host "Original poster already exists for Plex ID: $plexId."
                }

                # Calculate the formatted date for overlay
                $formattedDate = Calculate-Date -addDate $item.addDate -deleteAfterDays $deleteAfterDays
                Write-Host "Item $plexId has a formatted date: $formattedDate"

                # Apply overlay and upload the modified poster
                Copy-Item -Path $originalImagePath -Destination $tempImagePath -Force
                $tempImagePath = Add-Overlay -imagePath $tempImagePath -text "Leaving $formattedDate"
                Upload-Poster -posterPath $tempImagePath -metadataId $plexId
            } catch {
                Write-Warning "Failed to process Plex ID: $plexId. Error: $_"
            }
        }
    }

    # Compare currentState with newState to identify removed items
    foreach ($plexId in $currentState.Keys) {
        if (-not $newState.ContainsKey($plexId)) {
            Write-Host "Item $plexId detected as removed (not in newState)."
            $originalImagePath = "$ORIGINAL_IMAGE_PATH/$plexId.jpg"

            # Revert to the original poster if it exists
            if (Test-Path -Path $originalImagePath) {
                Write-Host "Reverting Plex ID: $plexId to original poster."
                Revert-ToOriginalPoster -plexId $plexId -originalImagePath $originalImagePath
            } else {
                Write-Warning "Original poster not found for Plex ID: $plexId. Skipping revert."
            }

            # Mark as removed in the state
            $newState[$plexId] = $false
        } else {
            Write-Host "Item $plexId is still in the collection."
        }
    }

    # Run janitorial logic
	$plexGUIDs = $currentState.Keys
	$maintainerrGUIDs = $newState.Keys
	Janitor-Posters -mediaList $plexGUIDs -maintainerrGUIDs $maintainerrGUIDs -newState $newState -originalImagePath $ORIGINAL_IMAGE_PATH -collectionName "All Media"


    # Save the new state
    $tempState = @{}
    foreach ($key in $newState.Keys) {
        $tempState["$key"] = $newState[$key]
    }
    Write-Host "Saving State: $(ConvertTo-Json $tempState -Depth 10)"
    Save-CollectionState -state $newState
}

# Ensure the images directories exist
if (-not (Test-Path -Path $IMAGE_SAVE_PATH)) {
    New-Item -ItemType Directory -Path $IMAGE_SAVE_PATH
}
if (-not (Test-Path -Path $ORIGINAL_IMAGE_PATH)) {
    New-Item -ItemType Directory -Path $ORIGINAL_IMAGE_PATH
}
if (-not (Test-Path -Path $TEMP_IMAGE_PATH)) {
    New-Item -ItemType Directory -Path $TEMP_IMAGE_PATH
}

# Run the main function in a loop with the specified interval
while ($true) {
    Process-MediaItems
    Write-Host "Waiting for $RUN_INTERVAL seconds before the next run."
    Start-Sleep -Seconds $RUN_INTERVAL
}
