[CmdletBinding()]
param([string]$ReceiptPath='')
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixtureParent=Join-Path $env:TEMP 'hwpx-harness-20260930'
$fixture=Join-Path $fixtureParent ('ack-fixture-'+[guid]::NewGuid().ToString('N').Substring(0,8))
try {
    $bin=Join-Path $fixture '.agent\shared\bin'
    [void][IO.Directory]::CreateDirectory($bin)
    $harness=Join-Path $fixture 'Harness.cs'
    $code=@'
using System;
using System.IO;
using System.Text;
using System.Reflection;
using System.Diagnostics;
using System.Collections.Generic;
using System.Web.Script.Serialization;
public static class Harness {
 static string root,index,work,target,manifest; static int checks; static JavaScriptSerializer json=new JavaScriptSerializer();
 static void Assert(bool ok,string label){if(!ok)throw new Exception(label); checks++;}
 static void Save(string p,object v){File.WriteAllText(p,json.Serialize(v));}
 static Dictionary<string,object> Read(string p){return json.Deserialize<Dictionary<string,object>>(File.ReadAllText(p));}
 static string Payload(string p){return Convert.ToBase64String(Encoding.UTF8.GetBytes(p)).TrimEnd('=').Replace('+','-').Replace('/','_');}
 static int Run(string uri,Func<ProcessStartInfo,Process> dispatch){return (int)typeof(HumanWorkOpenLauncher).GetMethod("Run",BindingFlags.Static|BindingFlags.NonPublic).Invoke(null,new object[]{new[]{uri},dispatch});}
 static string Uri(string form,string p,string nonce){return "hwpx-work-open:"+form+"open/"+Payload(p)+"/"+nonce;}
 static Dictionary<string,object> Ack(string nonce){string s=File.ReadAllText(Path.Combine(work,".ai","console-open-"+nonce+".js"));return json.Deserialize<Dictionary<string,object>>(s.Substring(s.IndexOf('=')+1).Trim().TrimEnd(';'));}
 public static void Main(){
  root=Directory.GetParent(AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\')).Parent.Parent.FullName;
  index=Path.Combine(root,".agent","index");work=Path.Combine(root,"20260908_fixture");Directory.CreateDirectory(index);Directory.CreateDirectory(Path.Combine(work,".ai"));
  target=Path.Combine(work,"document.csv");File.WriteAllText(target,"synthetic");manifest=Path.Combine(index,"targets.json");
  Save(Path.Combine(index,"delivery-system.json"),new{openProtocol="hwpx-work-open",openTargetManifest=".agent/index/targets.json",metadataFolderName=".ai",humanCabinet=root});
  Save(manifest,new{workFolders=new[]{new{workFolder=work,targets=new[]{target}}}});
  int dispatches=0;Func<ProcessStartInfo,Process> fake=p=>{dispatches++;return null;};
  foreach(string form in new[]{"","//"}){string n=Guid.NewGuid().ToString("N");Assert(Run(Uri(form,target,n),fake)==0,"dispatch exit");var a=Ack(n);Assert((bool)a["ok"]&&(bool)a["dispatched"]&&a["opened"]==null&&(string)a["status"]=="dispatched","dispatch is not observed open");}
  Assert(dispatches==2,"both URI forms dispatched once");
  string failed=Guid.NewGuid().ToString("N");Assert(Run(Uri("//",target,failed),p=>{throw new System.ComponentModel.Win32Exception(1155);})==1,"association failure exit");var f=Ack(failed);Assert(!(bool)f["ok"]&&(string)f["stage"]=="dispatch"&&(int)f["nativeErrorCode"]==1155,"native error ACK");
  File.Delete(target);string missing=Guid.NewGuid().ToString("N");Assert(Run(Uri("//",target,missing),fake)==6,"missing exit");Assert(!(bool)Ack(missing)["ok"],"missing gets failure ACK");
  File.WriteAllText(target,"synthetic");File.SetAttributes(target,FileAttributes.Hidden);string hidden=Guid.NewGuid().ToString("N");Assert(Run(Uri("//",target,hidden),fake)==6,"hidden blocked");Assert(!(bool)Ack(hidden)["ok"],"hidden ACK");File.SetAttributes(target,FileAttributes.Normal);
  string unknown=Guid.NewGuid().ToString("N");Assert(Run(Uri("//",Path.Combine(root,"unregistered.csv"),unknown),fake)==7,"unregistered blocked");Assert(!File.Exists(Path.Combine(work,".ai","console-open-"+unknown+".js")),"no untrusted ACK");Assert((int)Read(Path.Combine(Path.GetTempPath(),"hwpx-human-open-launcher",unknown+".json"))["exitCode"]==7,"pre-registration diagnostic");
  string corrupt=Guid.NewGuid().ToString("N");File.WriteAllText(manifest,"bad json");Assert(Run(Uri("//",target,corrupt),fake)==1,"corrupt manifest blocked");Assert((string)Read(Path.Combine(Path.GetTempPath(),"hwpx-human-open-launcher",corrupt+".json"))["stage"]=="manifest","corrupt manifest diagnostic");
  Assert(dispatches==2,"failures never dispatched");Assert(File.Exists(Path.Combine(work,".ai","console-open-"+missing+".js")),"later requests retain earlier correlated ACK");
  // Reproduce the real failure: the old workspace manifest is stale while Setup's
  // cabinet manifest contains the current HTML target. No registry/app is touched.
  string cabinet=Path.Combine(root,"cabinet");string cabinetIndex=Path.Combine(cabinet,".agent","index");Directory.CreateDirectory(cabinetIndex);
  work=Path.Combine(cabinet,"20260908_current");Directory.CreateDirectory(Path.Combine(work,".ai"));target=Path.Combine(work,"current.csv");File.WriteAllText(target,"current synthetic");
  Save(Path.Combine(index,"delivery-system.json"),new{openProtocol="hwpx-work-open",openTargetManifest=".agent/index/targets.json",metadataFolderName=".ai",humanCabinet=cabinet});
  Save(Path.Combine(cabinetIndex,"delivery-system.json"),new{openProtocol="hwpx-work-open",openTargetManifest=".agent/index/targets.json",metadataFolderName=".ai",humanCabinet=cabinet});
  Save(Path.Combine(cabinetIndex,"targets.json"),new{workFolders=new[]{new{workFolder=work,targets=new[]{target}}}});
  string resolved=Guid.NewGuid().ToString("N");Assert(Run(Uri("//",target,resolved),fake)==0,"old workspace binary resolves current cabinet despite corrupt workspace manifest");
  Assert((bool)Ack(resolved)["cabinetRuntimeResolved"]&&(bool)Ack(resolved)["ok"],"cabinet receives correlated success ACK");
  Assert(File.Exists(Path.Combine(Path.GetTempPath(),"hwpx-human-open-launcher",resolved+".json")),"system temporary folder receives diagnostic");
  Save(manifest,new{workFolders=new object[0]});
  var method=typeof(HumanWorkOpenLauncher).GetMethod("Run",BindingFlags.Static|BindingFlags.NonPublic);
  Assert((int)method.Invoke(null,new object[]{new[]{"--validate",Uri("//",target,Guid.NewGuid().ToString("N"))},fake})==0,"default validation uses same cabinet as real dispatch");
  Assert((int)method.Invoke(null,new object[]{new[]{"--validate",Uri("//",target,Guid.NewGuid().ToString("N")),manifest},fake})==7,"explicit fixture manifest never redirects to production cabinet");
  Save(Path.Combine(cabinetIndex,"delivery-system.json"),new{openProtocol="other-protocol",openTargetManifest=".agent/index/targets.json",metadataFolderName=".ai",humanCabinet=cabinet});
  Assert(Run(Uri("//",target,Guid.NewGuid().ToString("N")),fake)==3,"mismatching cabinet config fails closed");
  Assert(dispatches==3,"only the authorized target dispatched after cabinet resolution");
  Assert(!Directory.Exists(Path.Combine(root,".agent","cache"))&&!Directory.Exists(Path.Combine(cabinet,".agent","cache")),"launcher never creates a harness or cabinet diagnostic cache");
  Console.WriteLine(json.Serialize(new{ok=true,checks=checks,documentOpened=false,dispatch="injected fake; no real app launched",registryChanged=false}));
 }
}
'@
    [IO.File]::WriteAllText($harness,$code,[Text.UTF8Encoding]::new($true))
    $csc='C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $assembly=[System.Management.Automation.PowerShell].Assembly.Location
    $exe=Join-Path $bin 'Harness.exe'
    & $csc /nologo /target:exe /main:Harness /reference:System.Web.Extensions.dll "/reference:$assembly" "/out:$exe" (Join-Path $PSScriptRoot 'HumanWorkOpenLauncher.cs') $harness
    if($LASTEXITCODE -ne 0){throw 'Harness compile failed'}
    $previousTemp=$env:TEMP;$previousTmp=$env:TMP
    try {
        $env:TEMP=Join-Path $fixture 'system-temp';$env:TMP=$env:TEMP
        [void][IO.Directory]::CreateDirectory($env:TEMP)
        $result=& $exe
    } finally {$env:TEMP=$previousTemp;$env:TMP=$previousTmp}
    if($LASTEXITCODE -ne 0){throw 'Native ACK tests failed'}
    if($ReceiptPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReceiptPath),($result -join "`n"),[Text.UTF8Encoding]::new($true))}
    $result
} finally {
    $safe=[IO.Path]::GetFullPath($fixture)
    if([IO.Path]::GetDirectoryName($safe) -ine [IO.Path]::GetFullPath($fixtureParent) -or [IO.Path]::GetFileName($safe) -notlike 'ack-fixture-*'){throw 'Unsafe fixture cleanup'}
    if(Test-Path -LiteralPath $safe){Remove-Item -LiteralPath $safe -Recurse -Force}
}
