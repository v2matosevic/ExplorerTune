<#
    Catalog of known Windows shell extensions.

    THIS FILE IS THE POINT OF THE PROJECT. Every entry is a shell extension that
    loads inside explorer.exe and runs on right-click, on property reads, or on
    every icon paint. The catalog says what each one is and what it costs, so
    people can make an informed decision instead of guessing at GUIDs.

    Nothing here is blocked by default. Blocking is opt-in, per id, via
    explorertune.config.psd1. See CONTRIBUTING.md for how to add an entry.

    FIELDS
      Id        stable kebab-case identifier used in config and on the CLI
      Label     what a person calls this software
      Dll       one or more DLL file names, matched case-insensitively against
                the resolved InprocServer32 of each registered handler. Names,
                never paths: vendors move their install directories.
      Kind      contextmenu | overlay | property | thumbnail | copyhook | mixed
      Cost      when it runs, in plain words. The most useful field. A context
                menu handler runs on right-click; a property or thumbnail
                handler runs while you merely LOOK at a folder, which is much
                worse.
      Note      anything a person needs to know before blocking it, especially
                what visibly stops working
      Verified  Windows build the entry was last confirmed on, or ''
#>
@{
    Handlers = @(

        # ---- archivers ---------------------------------------------------
        @{
            Id = '7zip'; Label = '7-Zip'; Dll = @('7-zip.dll', '7-zip32.dll')
            Kind = 'contextmenu'
            Cost = 'right-click on files, folders and drives'
            Note = 'Blocking removes the 7-Zip submenu. The application and file associations keep working. Most people want to keep this.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'winrar'; Label = 'WinRAR'; Dll = @('rarext.dll', 'rarext32.dll')
            Kind = 'mixed'
            Cost = 'right-click, plus drag-and-drop onto folders'
            Note = 'Registers both a context menu and a drag-drop handler. Blocking removes both menus; extraction from the app is unaffected.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'peazip'; Label = 'PeaZip'; Dll = @('peazipshell.dll')
            Kind = 'contextmenu'
            Cost = 'right-click on files and folders'
            Note = ''
            Verified = ''
        }
        @{
            Id = 'poweriso'; Label = 'PowerISO'; Dll = @('PWRISOSH.DLL')
            Kind = 'contextmenu'
            Cost = 'right-click on files, folders AND every folder background'
            Note = 'Registers against *, Directory and Folder. If you only mount an ISO occasionally, the menu is not worth the per-click cost.'
            Verified = '10.0.26100'
        }

        # ---- cloud sync --------------------------------------------------
        @{
            Id = 'dropbox'; Label = 'Dropbox'; Dll = @('DropboxExt64.dll', 'DropboxExt.dll')
            Kind = 'mixed'
            Cost = 'every icon paint in a synced folder, right-click, and every folder copy or move'
            Note = 'Claims TEN of the fifteen honoured icon-overlay slots, plus a copy hook. Blocking removes sync badges - the sync itself is unaffected. Consider whether you read those badges before blocking. DLL name carries a version suffix, e.g. DropboxExt64.96.0.dll; matching is by prefix.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'onedrive'; Label = 'Microsoft OneDrive'; Dll = @('FileSyncShell64.dll', 'FileSyncShell.dll')
            Kind = 'mixed'
            Cost = 'icon paint in synced folders, right-click'
            Note = 'Blocking breaks the visible sync state and the "Always keep on this device" menu. Not recommended while you actually use OneDrive.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'megasync'; Label = 'MEGAsync'; Dll = @('MEGAShellExt64.dll', 'MEGAShellExtWin.dll')
            Kind = 'mixed'
            Cost = 'icon paint, right-click on files, folders and drives'
            Note = 'Pads its overlay key names with U+0001 to sort ahead of every competitor in the 15-slot queue. Known to leave registrations behind after uninstall - those are removed automatically as dead registrations, no config needed.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'gdrive'; Label = 'Google Drive'; Dll = @('googledrivesync64.dll', 'DriveFS.dll')
            Kind = 'mixed'
            Cost = 'icon paint in synced folders, right-click'
            Note = ''
            Verified = ''
        }
        @{
            Id = 'nextcloud'; Label = 'Nextcloud'; Dll = @('NCOverlays.dll', 'NCContextMenu.dll')
            Kind = 'mixed'
            Cost = 'icon paint in synced folders, right-click'
            Note = ''
            Verified = ''
        }

        # ---- creative suites ---------------------------------------------
        @{
            Id = 'adobe-coresync'; Label = 'Adobe Creative Cloud file sync'; Dll = @('CoreSync_x64.dll', 'CoreSync.dll')
            Kind = 'mixed'
            Cost = 'icon paint, plus right-click on files and folders'
            Note = 'Takes three overlay slots. Blocking removes Creative Cloud sync badges and the "Sync" submenu; Creative Cloud itself keeps syncing.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'adobe-acrobat'; Label = 'Adobe Acrobat context menu'; Dll = @('ContextMenuShim64.dll', 'ContextMenuShim.dll')
            Kind = 'contextmenu'
            Cost = 'right-click on EVERY file, not just PDFs'
            Note = 'Adds "Combine files in Acrobat". Registered against * so it loads for any file type.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'adobe-explorer'; Label = 'Adobe Explorer extension'; Dll = @('AdobeExplorerExtension.dll')
            Kind = 'mixed'
            Cost = 'loaded into explorer.exe at shell start'
            Note = ''
            Verified = '10.0.26100'
        }
        @{
            Id = 'corel'; Label = 'Corel property and thumbnail handlers'; Dll = @('ShellVista.dll', 'FileInfoProvider.dll')
            Kind = 'property'
            Cost = 'every time you LOOK at a folder containing its file types, not just right-click'
            Note = 'Registered per file extension, so these do not appear in a context-menu scan but are loaded in the process. Blocking loses Corel thumbnails and extended file properties in the details pane.'
            Verified = '10.0.26100'
        }

        # ---- editors and dev tools ---------------------------------------
        @{
            Id = 'notepadpp'; Label = 'Notepad++'; Dll = @('NppShell_06.dll', 'NppShell_05.dll', 'NppShell.dll', 'NppModernShell.dll')
            Kind = 'contextmenu'
            Cost = 'right-click on every file'
            Note = 'Adds "Edit with Notepad++". The file association still works after blocking, so double-click and "Open with" are unaffected.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'vscode'; Label = 'Visual Studio Code'; Dll = @()
            Kind = 'contextmenu'
            Cost = 'nothing measurable'
            Note = 'Listed for completeness only. VS Code registers STATIC verbs, not a shellex DLL, so it costs nothing at runtime and there is nothing here to block. This is the pattern every installer should follow.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'tortoisegit'; Label = 'TortoiseGit'; Dll = @('TortoiseGitStub64.dll', 'TortoiseGitStub32.dll')
            Kind = 'mixed'
            Cost = 'every icon paint inside a working copy, right-click'
            Note = 'Overlay handlers over a large repository are one of the most expensive things you can put in Explorer. TortoiseGit has its own include/exclude path settings - prefer configuring those over blocking outright.'
            Verified = ''
        }
        @{
            Id = 'tortoisesvn'; Label = 'TortoiseSVN'; Dll = @('TortoiseStub64.dll', 'TortoiseStub32.dll')
            Kind = 'mixed'
            Cost = 'every icon paint inside a working copy, right-click'
            Note = 'Same shape as TortoiseGit.'
            Verified = ''
        }
        @{
            Id = 'filezilla'; Label = 'FileZilla copy hook'; Dll = @('fzshellext_64.dll', 'fzshellext.dll')
            Kind = 'copyhook'
            Cost = 'EVERY folder copy, move, rename and delete'
            Note = 'A copy hook is consulted on every one of those operations, whether or not FileZilla is running. Among the cheapest wins in the catalog.'
            Verified = '10.0.26100'
        }

        # ---- utilities ----------------------------------------------------
        @{
            Id = 'recuva'; Label = 'Recuva'; Dll = @('RecuvaShell64.dll', 'RecuvaShell.dll')
            Kind = 'contextmenu'
            Cost = 'right-click on folders and drives'
            Note = 'Adds "Scan for deleted files". Run Recuva from its own window instead.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'ccleaner'; Label = 'CCleaner'; Dll = @('CCleanerShellExt64.dll', 'CCleanerShellExt.dll')
            Kind = 'contextmenu'
            Cost = 'right-click on folders and the Recycle Bin'
            Note = ''
            Verified = ''
        }
        @{
            Id = 'malwarebytes'; Label = 'Malwarebytes scan menu'; Dll = @('mbshlext.dll')
            Kind = 'contextmenu'
            Cost = 'right-click on files and folders'
            Note = 'Only the right-click "Scan with Malwarebytes" entry. Real-time protection is a driver and a service and is NOT affected by blocking this.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'nvidia'; Label = 'NVIDIA Control Panel menu'; Dll = @('nvshext.dll', 'nvui.dll')
            Kind = 'contextmenu'
            Cost = 'right-click on the desktop and folder backgrounds'
            Note = 'Blocking removes "NVIDIA Control Panel" from the desktop right-click menu. The panel is still reachable from the Start menu.'
            Verified = '10.0.26100'
        }
        @{
            Id = 'winmerge'; Label = 'WinMerge'; Dll = @('ShellExtensionX64.dll', 'ShellExtension.dll')
            Kind = 'contextmenu'
            Cost = 'right-click on files and folders'
            Note = ''
            Verified = ''
        }
        @{
            Id = 'teracopy'; Label = 'TeraCopy'; Dll = @('TeraCopyExt64.dll', 'TeraCopyExt.dll')
            Kind = 'mixed'
            Cost = 'right-click, plus drag-and-drop'
            Note = 'Blocking removes the drag-drop integration TeraCopy exists for. Uninstall instead if you do not want it.'
            Verified = ''
        }
    )
}
