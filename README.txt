===============================================================
 Wired Steam Link VR
===============================================================

Runs Steam Link over your USB cable instead of Wi-Fi. Steam Link
will show the connection as USB, because that is what it is now.

Measured on a Quest 2 with a USB 3 cable:

    round trip to the PC     0.7 ms
    throughput               ~756 Mbit/s

There are four steps. Steps 1 to 3 are one-time setup. After
that you only ever do step 4.


---------------------------------------------------------------
 WHAT YOU NEED
---------------------------------------------------------------

  * A Quest headset
  * A USB 3 cable, in a USB 3 port (blue, or marked SS)
  * Windows 10 or 11, and admin rights (it asks via UAC)
  * A Meta account you can sign into on a computer and a phone

Nothing needs to be installed. Do not move these files apart -
they have to stay in the same folder.

Tested on a Quest 2. Quest 3 / 3S should work the same way but
have not been tested.


===============================================================
 STEP 1 - MAKE A DEVELOPER ACCOUNT   (one time, on a computer)
===============================================================

Developer mode is the only way to switch the USB port into
network mode. It is free, and you are not publishing anything -
Meta just requires a verified account before the option shows up.

  1. Go to  https://developers.meta.com/horizon/manage/organizations/create/
     Sign in with the SAME Meta account your headset uses.

  2. You need an "organization". If you have never made one,
     the site will prompt you to create one. Any name will do.

  3. Accept the developer agreement when asked.

  4. Verify the account. Meta requires:
       - two-factor authentication turned on, or
       - a phone number or a credit card on file
     Developer mode will NOT appear until this is finished.

This step is where nearly everyone gets stuck. If the toggle in
step 2 is missing, come back and finish this one.


===============================================================
 STEP 2 - TURN ON DEVELOPER MODE     (one time, on your phone)
===============================================================

  1. Install the "Meta Horizon" app (this used to be called the
     Oculus app). Sign in with the same account as above.

  2. Turn your headset on and keep it on, so the phone can
     reach it.

  3. In the app, tap  Menu  ->  Devices.

  4. Select your headset. It must say Connected. If it does not,
     the phone cannot see it - check Bluetooth and that both are
     on the same Wi-Fi.

  5. Tap  Headset settings  ->  Developer mode.

  6. Switch Developer mode ON.

  7. Reboot the headset (hold the power button, choose Restart).

Meta moves these menus around between app versions. If the
wording differs slightly, look for anything named Developer.


===============================================================
 STEP 3 - ALLOW USB DEBUGGING        (one time, headset + PC)
===============================================================

  1. Plug the headset into the PC.

  2. Run  adb-scan.bat  from this folder.

  3. Put the headset on. You should see a prompt:
     "Allow USB debugging?"
     Tick "Always allow from this computer", then Allow.
     If you also get "Allow access to data", allow that too.

  4. Run  adb-scan.bat  again. Your headset should now be listed
     with the word  device  after it.

     If it says  unauthorized   -> step 3 did not take. Unplug,
                                   plug back in, watch for the
                                   prompt again.
     If nothing is listed       -> developer mode is not on yet,
                                   or the cable is charge-only.
                                   Try a different cable or port.


===============================================================
 STEP 4 - RUN IT                     (every time you play)
===============================================================

  1. Plug the headset in.

  2. Run  NCM-Run.bat  and approve the UAC prompt.

  3. Wait until it says  Link is up.

  4. Put the headset on, open Steam Link, and connect to your
     computer. It should show the connection as USB.

Leave the window open while you play. When you are done, press
any key in it - that puts everything back to normal.

There are two ways this can end up working, and the script picks
whichever your PC supports. Either is fine:

  "NAT is up"
      The headset gets internet through the cable. Leave its
      Wi-Fi on - after about 15 seconds the headset checks the
      cable and switches to it by itself.

  "Windows NAT is not available on this PC"
      Sharing your internet needs a Windows part that only comes
      with Hyper-V, so Windows Home usually does not have it.
      The script handles this by switching the headset's Wi-Fi
      off for you, which makes the cable its only route. Steam
      Link does not need the headset to have internet. Wi-Fi is
      switched back on when you exit.


---------------------------------------------------------------
 WHAT IS IN THIS FOLDER
---------------------------------------------------------------

  NCM-Run.bat        <- the one you run
  adb-scan.bat       checks the headset is talking to the PC
  QuestNcmLink.ps1   does the actual work
  adb.exe            }
  AdbWinApi.dll      } Android platform-tools
  AdbWinUsbApi.dll   }
  README.txt         this file
  README.md          the same thing, for the online page
  LICENSE            MIT - adb.exe is Google's, under its own terms

If you have followed another guide that had you copy adb into
C:\Android and add it to your system PATH, you can undo both -
this uses the adb.exe sitting next to it instead.


---------------------------------------------------------------
 WHAT IT CHANGES, AND UNDOES
---------------------------------------------------------------

While running, it switches the headset's USB port to network
mode, gives the PC the address 192.168.42.1 on the new adapter,
hands the headset 192.168.42.2, adds a NAT so the headset gets
internet through the cable, and adds one firewall rule so Steam
can be reached over it.

Every one of those is undone when you press a key to exit.

If the window gets killed instead of closed properly, the worst
case is the USB stays in network mode. Unplugging the cable or
rebooting the headset clears it - the change is never permanent.


---------------------------------------------------------------
 IF IT DOES NOT WORK
---------------------------------------------------------------

"No headset found on USB"
    Go back to step 3 and run adb-scan.bat.

"Windows never showed a UsbNcm adapter"
    Your headset's build may not support this. Check with:
        adb.exe shell svc usb getFunctions
    It should print  ncm . If it prints nothing, the headset
    refused. Also look in Device Manager, under Network
    adapters, for anything with a yellow warning icon.

    On Windows 10 the NCM device shows up under Other devices
    with Code 28, because Windows 10 does not match its built-in
    UsbNcm driver to it. The script installs that driver for you;
    if that fails, do it by hand while step 2 is running:
    Update driver > Browse my computer > Let me pick > Network
    adapters > Microsoft > UsbNcm Host Device. Windows remembers
    it, so this is only needed once.

"The headset never took a lease"
    Something else on the PC is probably using UDP port 67 -
    another DHCP server, or Internet Connection Sharing.
    In PowerShell:
        Get-NetUDPEndpoint -LocalPort 67

"Headset already has a fixed address"
    Not an error. Newer headset builds give the cable a fixed
    address themselves (for Steam Link's own wired mode) instead
    of asking for one, so the script puts the PC in that same
    network and skips DHCP. Connect Steam Link to the PC address
    the script prints.

It says Link is up, but Steam Link still uses Wi-Fi
    If the script said "NAT is up", give it 15 seconds to check
    the cable for internet, then it switches over on its own.
    Otherwise the script turns the headset's Wi-Fi off for you;
    if that did not happen, turn it off by hand.

Steam does not see the PC at all
    Firewall. The script adds a rule, but third-party security
    software may need Steam allowed on 192.168.42.0/24.

You use a VPN app on the headset
    Turn it off. A VPN grabs all traffic from every app and will
    swallow the cable connection no matter what.


---------------------------------------------------------------
 OPTIONS
---------------------------------------------------------------

  NCM-Run.bat -WifiOff

Skips the internet sharing and just switches the headset's Wi-Fi
off, so the cable is its only route. Wi-Fi is switched back on
when you exit. The script does this by itself when your PC
cannot share internet, so you only need this switch if you want
to force it - for example if the NAT clashes with something else
on your PC.

(-NoInternet is accepted as an older name for the same switch.)
