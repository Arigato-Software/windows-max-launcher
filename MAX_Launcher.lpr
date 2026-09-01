program MAX_Launcher;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, umain
  { you can add units after this };

{$R *.res}

begin
  RequireDerivedFormResource:=True;
  Application.Title:='MAX лаунчер';
  Application.Scaled:=True;
  Application.Initialize;
  Application.CreateForm(TFMain, FMain);
  Application.Run;
end.

