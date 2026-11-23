# Embeds a multi-resolution .ico file into a Windows .exe as RT_GROUP_ICON (ID 1).
param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$IcoPath
)
$ErrorActionPreference = 'Stop'
$ExePath = (Resolve-Path $ExePath).Path
$IcoPath = (Resolve-Path $IcoPath).Path

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;

public static class IconEmbedder {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr BeginUpdateResource(string pFileName, bool bDeleteExistingResources);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateResource(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, ushort wLanguage, byte[] lpData, uint cbData);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool EndUpdateResource(IntPtr hUpdate, bool fDiscard);

    public static void Embed(string exePath, string icoPath) {
        byte[] ico = File.ReadAllBytes(icoPath);
        ushort count = BitConverter.ToUInt16(ico, 4);
        IntPtr h = BeginUpdateResource(exePath, false);
        if (h == IntPtr.Zero) throw new Exception("BeginUpdateResource failed: " + Marshal.GetLastWin32Error());
        try {
            using (var grp = new MemoryStream())
            using (var bw = new BinaryWriter(grp)) {
                bw.Write((ushort)0);
                bw.Write((ushort)1);
                bw.Write(count);
                for (int i = 0; i < count; i++) {
                    int off = 6 + i * 16;
                    byte w = ico[off + 0];
                    byte ht = ico[off + 1];
                    byte cc = ico[off + 2];
                    byte res = ico[off + 3];
                    ushort planes = BitConverter.ToUInt16(ico, off + 4);
                    ushort bpp = BitConverter.ToUInt16(ico, off + 6);
                    uint bytesInRes = BitConverter.ToUInt32(ico, off + 8);
                    uint imgOffset = BitConverter.ToUInt32(ico, off + 12);

                    byte[] img = new byte[bytesInRes];
                    Buffer.BlockCopy(ico, (int)imgOffset, img, 0, (int)bytesInRes);
                    ushort id = (ushort)(i + 1);
                    if (!UpdateResource(h, (IntPtr)3, (IntPtr)id, 0, img, bytesInRes))
                        throw new Exception("UpdateResource RT_ICON failed");

                    bw.Write(w); bw.Write(ht); bw.Write(cc); bw.Write(res);
                    bw.Write(planes); bw.Write(bpp); bw.Write(bytesInRes); bw.Write(id);
                }
                byte[] gbytes = grp.ToArray();
                if (!UpdateResource(h, (IntPtr)14, (IntPtr)1, 0, gbytes, (uint)gbytes.Length))
                    throw new Exception("UpdateResource RT_GROUP_ICON failed");
            }
            if (!EndUpdateResource(h, false))
                throw new Exception("EndUpdateResource failed: " + Marshal.GetLastWin32Error());
        } catch {
            EndUpdateResource(h, true);
            throw;
        }
    }
}
"@

[IconEmbedder]::Embed($ExePath, $IcoPath)
Write-Host "Embedded $IcoPath into $ExePath"
