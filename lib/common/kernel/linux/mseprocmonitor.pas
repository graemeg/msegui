{ MSEgui Copyright (c) 2008-2009 by Martin Schreiber

    See the file COPYING.MSE, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
}
unit mseprocmonitor;
{$ifdef FPC}{$mode objfpc}{$h+}{$interfaces corba}{$endif}
interface
uses
 msesystypes,mseglob,msetypes,mselibc;
 
 {$include ../mseprocmonitor.inc}

procedure sigchildcallback;
function timedwaitpid(__pid: __pid_t; __stat_loc: plongint;
                                              const waitus: integer): __pid_t;
                //waitus must be > 0
                //result -1 -> error, -2 -> timeout

implementation
uses
 mseapplication,msedatalist,msearrayutils,msesysintf1,msesysutils,sysutils;
 
type
 procinfoty = record
  prochandle: prochandlety;
  dest: iprocmonitor;
  data: pointer;
 end;
 procinfoarty = array of procinfoty;
var
 infos: procinfoarty;
  
function pro_listentoprocess(const aprochandle: prochandlety;
                    const adest: iprocmonitor; const adata: pointer): boolean;
begin
 application.lock;
 setlength(infos,high(infos)+2);
 with infos[high(infos)] do begin
  prochandle:= aprochandle;
  dest:= adest;
  data:= adata;
 end;
 application.unlock;
 result:= true;
end;

procedure pro_unlistentoprocess(const aprochandle: prochandlety;
                                     const adest: iprocmonitor);
var
 int1: integer;
begin
 application.lock;
 for int1:= high(infos) downto 0 do begin
  with infos[int1] do begin
   if (prochandle = aprochandle) and (dest = adest) then begin
    deleteitem(infos,typeinfo(procinfoarty),int1);
   end;
  end;
 end;
 application.unlock;
end;

procedure checkchildproc();
var
 int1,int2,int3: integer;
 dwo1: dword;
 execresult: integer;
begin
 application.lock;
 int1:= high(infos);
 while int1 >= 0 do begin
  int3:= waitpid(infos[int1].prochandle,@dwo1,wnohang);
  if (int3 > 0) and (wifexited(dwo1) or wifsignaled(dwo1)) then begin
   execresult:= wexitstatus(dwo1);
  end
  else begin
   execresult:= -2; //still running for int3 = 0
   if (int3 < 0) and (sys_getlasterror() = ECHILD) then begin
    execresult:= -1;
   end;
  end;
  if execresult >= -1 then begin
   for int2:= int1 downto 0 do begin
    with infos[int2] do begin
     if prochandle = infos[int1].prochandle then begin     
      if dest <> nil then begin
       dest.processdied(prochandle,execresult,data);
      end;
      deleteitem(infos,typeinfo(procinfoarty),int2);
      if int2 <> int1 then begin
       dec(int1);
      end;
     end;
    end;
   end;
  end;
  dec(int1);
 end;
 application.unlock;
end;

procedure pro_killzombie(const aprochandle: prochandlety);
begin
 pro_listentoprocess(aprochandle,nil,nil);
end;

type
 psemelety = ^semelety;
 semelety = record
  prev: psemelety;
  next: psemelety;
  sem: semty;
 end;
 
var
 semaphorelock: mutexty;
 semaphores: psemelety;
{$ifdef mse_debugprocmonitor}
var
 semcount: int32;

procedure checksemaphores();
var
 i1: int32;
 po1: psemelety;
begin
 i1:= 0;
 po1:= semaphores;
 while po1 <> nil do begin
  inc(i1);
  po1:= po1^.next;
 end;
 if i1 <> semcount then begin
  raise exception.create('Invalid procmonitor semaphores');
 end;
end;

{$endif}
  
procedure sigchildcallback();
var
 po1: psemelety;
begin
{$ifdef mse_debugprocmonitor}
 checksemaphores();
{$endif}
 po1:= semaphores;
 while po1 <> nil do begin
  sys_sempost(po1^.sem);
  po1:= po1^.next;
 end; 
end;

function timedwaitpid(__pid: __pid_t; __stat_loc: plongint;
                                             const waitus: integer): __pid_t;
                //waitus must be > 0
                //result -1 -> error, -2 -> timeout
var
 semele: semelety;
 lwo1: longword;
 int1: integer;
begin
 result:= -1;
 if waitus > 0 then begin
  lwo1:= timestep(waitus);
  sys_semcreate(semele.sem,0);

  sys_mutexlock(semaphorelock);
{$ifdef mse_debugprocmonitor}
  checksemaphores();
{$endif}
  semele.prev:= semaphores;
  semele.next:= nil;
  if semaphores = nil then begin
   interlockedexchange(semaphores,@semele);
  end
  else begin
   interlockedexchange(semaphores^.next,@semele);
  end;
{$ifdef mse_debugprocmonitor}
  inc(semcount);
  checksemaphores();
{$endif}
  sys_mutexunlock(semaphorelock);

  while true do begin
   repeat
    result:= waitpid(__pid,__stat_loc,wnohang);
   until (result >= 0) or (sys_getlasterror <> eintr);
   if (result = __pid) or (result < 0) then begin
    break;
   end;
   int1:= lwo1-timestamp;
   if int1 > 0 then begin
    sys_semwait(semele.sem,int1);
   end
   else begin
    result:= waitpid(__pid,__stat_loc,wnohang);
    if result < 0 then begin
     result:= -2;
    end;
    break;
   end;
  end;
  
  sys_mutexlock(semaphorelock);
{$ifdef mse_debugprocmonitor}
  checksemaphores();
{$endif}
//  if semele.prev = nil then begin
  if semaphores = @semele then begin
   interlockedexchange(semaphores,semele.next);
  end
  else begin
   interlockedexchange(semele.prev^.next,semele.next);
  end;
{$ifdef mse_debugprocmonitor}
  dec(semcount);
  checksemaphores();
{$endif}
  sys_mutexunlock(semaphorelock);

  sys_semdestroy(semele.sem);
 end;
end;

initialization
 onhandlesigchld:= @checkchildproc;
 sys_mutexcreate(semaphorelock);
 
finalization
 onhandlesigchld:= nil;
 sys_mutexdestroy(semaphorelock);
end.
