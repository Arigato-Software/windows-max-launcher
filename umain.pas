unit umain;

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls,
  StdCtrls, Menus;

type

  { TFMain }

  TFMain = class(TForm)
    Button1: TButton;
    Button3: TButton;
    Button4: TButton;
    Button5: TButton;
    CheckBox1: TCheckBox;
    CheckBox2: TCheckBox;
    CheckBox3: TCheckBox;
    CheckBox4: TCheckBox;
    Label1: TLabel;
    Label2: TLabel;
    LabeledEdit1: TLabeledEdit;
    LabeledEdit2: TLabeledEdit;
    MenuItem1: TMenuItem;
    MenuItem2: TMenuItem;
    OpenDialog1: TOpenDialog;
    PopupMenu1: TPopupMenu;
    Timer1: TTimer;
    Timer10: TTimer;
    Timer2: TTimer;
    Timer3: TTimer;
    Timer4: TTimer;
    Timer5: TTimer;
    Timer6: TTimer;
    Timer7: TTimer;
    Timer8: TTimer;
    Timer9: TTimer;
    TrayIcon1: TTrayIcon;
    procedure Button1Click(Sender: TObject);
    procedure Button2Click(Sender: TObject);
    procedure Button3Click(Sender: TObject);
    procedure Button4Click(Sender: TObject);
    procedure Button5Click(Sender: TObject);
    procedure CheckBox1Change(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDblClick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure MenuItem1Click(Sender: TObject);
    procedure MenuItem2Click(Sender: TObject);
    procedure Timer10Timer(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
    procedure Timer2Timer(Sender: TObject);
    procedure Timer3Timer(Sender: TObject);
    procedure Timer4Timer(Sender: TObject);
    procedure Timer5Timer(Sender: TObject);
    procedure Timer6Timer(Sender: TObject);
    procedure Timer7Timer(Sender: TObject);
    procedure Timer8Timer(Sender: TObject);
    procedure Timer9Timer(Sender: TObject);
    procedure TrayIcon1Click(Sender: TObject);
  private
    FAutoRun: Boolean;
    FEmulatorPID: Integer;
    FEmulatorRunning: Boolean;
    FSplashBitmap, FSplashStretchBitmap: TBitmap;
    FIsLDPlayer: Boolean;
    FClickClose: Boolean;
    FSharedFiles: TStringList;
    FBootStartTick: Cardinal;
    FADBRetryCount: Integer;   // счётчик попыток для текущего состояния
    procedure ShowTrayHint(const Title, Message: string);
    function ReadRegValue(ValueName: String): String;
    procedure WriteRegValue(ValueName, ValueData: String);
    function StartEmulator(const ExePath: string): Boolean;
    function IsClipboardEmpty: Boolean;
    procedure ClearClipboard;
    procedure LoadSplashImage;
    function PrepareSplashForWindow(W, H: Integer): Boolean;
    procedure MinimizeToTray;    // Свернуть в трей
    procedure RestoreFromTray;   // Восстановить из трея
    procedure ChangeEmulatorIcon(MainWnd: HWND);
  public

  end;

var
  FMain: TFMain;

implementation

{$R *.lfm}

uses Registry, Process, Clipbrd, fpjson, jsonparser;

type
  TLDConfig = record
    JSON: TJSONObject;
    Valid: Boolean;
  end;

// Стартовое изображение
const
  SplashFileName = 'splash.jpg';

// Блокировка рекламных окон по классу
const
  AD_CLASSES: array of string = (
    'ADFullScreenFrame',
    'adframe',
    'LDLDBroadScreenWndIE'
  );

const
  REG_KEY = 'SOFTWARE\Arigato Software\MAX_Launcher'; // Ключ реестра для настроек
  REG_PATH_EMULATOR = 'EmulatorPath';
  REG_EMULATOR_AUTORUN = 'EmulatorAutorun';
  REG_MAX_AUTORUN = 'MaxAutorun';
  REG_CLOSE_WITH_EMULATOR = 'CloseWithEmulator';

const
  MAX_PACKAGE = 'ru.oneme.app';
  MAX_ACTIVITY = 'one.me.android.MainActivity';  // без точки в начале!
  ADB_PORT = 5555;

const
  LDP_LAUNCHER = 'com.ldmnq.launcher3';
  PCL_PACKAGE = 'ru.whatau.cpl';

var
  GlobalPID: DWORD;
  GlobalFoundWindow: HWND;
  LDConfig: TLDConfig;
  ADBPath, ADBDevice: string;

function RunADB(Args: string; out Output: string): Boolean;
var
  P: TProcess;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: Integer;
  Idx: Integer;
begin
  Result := False;
  Output := '';
  if not FileExists(ADBPath) then Exit;

  P := TProcess.Create(nil);
  try
    P.Executable := ADBPath;

    while Args <> '' do begin
      Idx := Pos(' ', Args);
      if Idx > 0 then begin
        P.Parameters.Add(Copy(Args, 1, Idx - 1));
        Delete(Args, 1, Idx);
      end
      else begin
        P.Parameters.Add(Args);
        Break;
      end;
    end;

    P.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    P.Execute;

    // Читаем пока процесс работает
    while P.Running do
    begin
      BytesRead := P.Output.Read(Buffer, SizeOf(Buffer));
      if BytesRead > 0 then
        Output := Output + Copy(Buffer, 1, BytesRead);
      Sleep(10);
    end;

    // Дочитываем остаток после завершения
    repeat
      BytesRead := P.Output.Read(Buffer, SizeOf(Buffer));
      if BytesRead > 0 then
        Output := Output + Copy(Buffer, 1, BytesRead);
    until BytesRead = 0;

    P.WaitOnExit;
    Output := LowerCase(Output);
    Result := (P.ExitStatus = 0);
  finally
    P.Free;
  end;
end;

// Загрузка конфига в память (вызывать один раз)
function LoadLDConfig(const ConfigPath: string): TLDConfig;
var
  Content: TStringList;
  JSONData: TJSONData;
begin
  Result.Valid := False;
  Result.JSON := nil;

  if not FileExists(ConfigPath) then Exit;

  Content := TStringList.Create;
  try
    Content.LoadFromFile(ConfigPath);
    // GetJSON парсит строку и возвращает TJSONData (базовый тип)
    JSONData := GetJSON(Content.Text);
    if Assigned(JSONData) and (JSONData is TJSONObject) then
    begin
      Result.JSON := TJSONObject(JSONData);
      Result.Valid := True;
    end
    else if Assigned(JSONData) then
      JSONData.Free; // не JSONObject — освобождаем
  except
    on E: Exception do
      if Assigned(JSONData) then JSONData.Free;
  end;
  Content.Free;
end;

// Освобождение ресурсов
procedure FreeLDConfig(var Config: TLDConfig);
begin
  if Assigned(Config.JSON) then
    Config.JSON.Free;
  Config.JSON := nil;
  Config.Valid := False;
end;

// Геттеры
function GetSharedPictures(const Config: TLDConfig): string;
var
  J: TJSONData;
  S: string;
begin
  Result := '';
  if not Config.Valid then Exit;
  J := Config.JSON.Find('statusSettings.sharedPictures');
  if Assigned(J) then
  begin
    S := J.AsString;
    if S <> '' then
    begin
      Result := StringReplace(S, '/', '\', [rfReplaceAll]);
      Result := ExcludeTrailingPathDelimiter(Result);
      if not DirectoryExists(Result) then Result := '';
    end;
  end;
end;

function GetADBDebug(const Config: TLDConfig): Boolean;
var
  J: TJSONData;
begin
  Result := False;
  if not Config.Valid then Exit;
  J := Config.JSON.Find('basicSettings.adbDebug');
  if Assigned(J) then
    Result := J.AsInteger <> 0;
end;

// Установка значения (перезаписывает файл)
procedure SetADBDebug(const ConfigPath: string; const Config: TLDConfig; Enable: Boolean);
var
  Content: TStringList;
  JSONObj: TJSONObject;
begin
  if not FileExists(ConfigPath) or not Config.Valid then Exit;

  JSONObj := Config.JSON;

  try
    Content := TStringList.Create;
    JSONObj.Integers['basicSettings.adbDebug'] := Ord(Enable);
    // Сохраняем с форматированием (Indent = 2 для читаемости)
    Content.Text := JSONObj.FormatJSON();
    Content.SaveToFile(ConfigPath);
  finally
    Content.Free;
  end;
end;

function GetLDPlayerPath: string;
var
  Reg: TRegistry;
  RootKeys: array of HKEY = (
    HKEY_CURRENT_USER,
    HKEY_LOCAL_MACHINE
  );
  i: Integer;
begin
  Result := '';

  Reg := TRegistry.Create;
  try
    for i := 0 to High(RootKeys) do
    begin
      Reg.RootKey := RootKeys[i];
      if Reg.OpenKeyReadOnly('SOFTWARE\XuanZhi\LDPlayer9') then
      begin
        if Reg.ValueExists('InstallDir') then
          Result := Reg.ReadString('InstallDir');
        Reg.CloseKey;

        if Result <> '' then
          Break; // Нашли - выходим
      end;
    end;
  finally
    Reg.Free;
  end;

  // Проверяем существование файла
  if Result <> '' then
  begin
    Result := ExcludeTrailingPathDelimiter(Result) + '\dnplayer.exe';
    if not FileExists(Result) then
      Result := '';
  end;
end;

function IsProcessRunning(PID: Integer): Boolean;
var
  hProcess: THandle;
  ExitCode: DWORD;
begin
  Result := False;
  hProcess := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, PID);

  if hProcess <> 0 then
  try
    ExitCode := 0;
    if GetExitCodeProcess(hProcess, ExitCode) then
      Result := (ExitCode = STILL_ACTIVE);
  finally
    CloseHandle(hProcess);
  end;
end;

function EnumWindowsProc(H: HWND; Param: LPARAM): WINBOOL; stdcall;
var
  ProcessID: DWORD;
begin
  GetWindowThreadProcessId(H, @ProcessID);
  if (ProcessID = GlobalPID) and IsWindowVisible(H) and (GetParent(H) = 0) then
  begin
    GlobalFoundWindow := H;
    Result := False; // Нашли главное окно - прерываем
  end
  else
    Result := True; // Продолжаем поиск
end;

function FindMainWindowByPID(PID: DWORD): HWND;
begin
  GlobalPID := PID;
  GlobalFoundWindow := 0;
  EnumWindows(@EnumWindowsProc, PID);
  Result := GlobalFoundWindow;
end;

function CloseMainWindowByPID(PID: Integer; Timeout: Integer = 10000): Boolean;
var
  MainWnd: HWND;
  StartTime: Cardinal;
begin
  Result := False;

  MainWnd := FindMainWindowByPID(PID);
  if MainWnd <> 0 then
  begin
    PostMessage(MainWnd, WM_SYSCOMMAND, SC_CLOSE, 0);

    // Ждем закрытия
    StartTime := GetTickCount;
    while IsProcessRunning(PID) and (GetTickCount - StartTime < Timeout) do
    begin
      Sleep(50);
      Application.ProcessMessages;
    end;

    if IsProcessRunning(PID) then
    begin
      // Если не закрылся - принудительно
      {TerminateProcess(OpenProcess(PROCESS_TERMINATE, False, PID), 0);
      Result := True;}
    end else begin
      Result := True;
    end;
  end;
end;

function ScanSharedFolder(const Path: string): TStringList;
var
  FileList: TStringList;

  // Вложенная процедура для рекурсивного обхода
  procedure ScanDirectory(const CurrentPath: string);
  var
    SearchRec: TSearchRec;
    FullPath: string;
  begin
    if FindFirst(CurrentPath + PathDelim + '*', faAnyFile, SearchRec) = 0 then
    begin
      repeat
        // Пропускаем системные папки "." и ".."
        if (SearchRec.Name = '.') or (SearchRec.Name = '..') then
          Continue;

        // Формируем полный путь
        FullPath := CurrentPath + PathDelim + SearchRec.Name;

        if (SearchRec.Attr and faDirectory) = faDirectory then
        begin
          // Если это папка - рекурсивно сканируем её
          ScanDirectory(FullPath);
        end
        else
        begin
          // Если это файл - добавляем в список
          FileList.Add(FullPath);
        end;
      until FindNext(SearchRec) <> 0;
      SysUtils.FindClose(SearchRec);
    end;
  end;

begin
  FileList := TStringList.Create;
  try
    // Проверяем существование папки
    if DirectoryExists(Path) then
    begin
      ScanDirectory(Path);
    end;
    Result := FileList;
  except
    on E: Exception do
    begin
      Result := FileList;
    end;
  end;
end;

// Удаление директории с поддиректориями
function DeleteDirectory(const DirName: string): Boolean;
var
  SearchRec: TSearchRec;
  FileName: string;
begin
  Result := False;
  if not DirectoryExists(DirName) then Exit(True);
  if FindFirst(DirName + PathDelim + '*', faAnyFile, SearchRec) = 0 then
  begin
    repeat
      if (SearchRec.Name = '.') or (SearchRec.Name = '..') then Continue;
      FileName := DirName + PathDelim + SearchRec.Name;
      if (SearchRec.Attr and faDirectory) = faDirectory then
      begin
        if not DeleteDirectory(FileName) then
        begin
          FindClose(SearchRec);
          Exit(False);
        end;
      end
      else
      begin
        if not SysUtils.DeleteFile(FileName) then
        begin
          FindClose(SearchRec);
          Exit(False);
        end;
      end;
    until FindNext(SearchRec) <> 0;
    FindClose(SearchRec);
  end;
  Result := RemoveDir(DirName);
end;

// Попытка блокировки рекламы (удаление директории cache и замена на файл)
procedure BlockLDPlayerAds;
var
  AppDataPath, XuanZhiPath, CachePath: string;
begin
  AppDataPath := GetEnvironmentVariable('APPDATA');
  if AppDataPath = '' then Exit;
  XuanZhiPath := AppDataPath + '\XuanZhi9';
  if not DirectoryExists(XuanZhiPath) then Exit; // если папка XuanZhi9 отсутствует – ничего не делаем

  CachePath := XuanZhiPath + '\cache';

  // Удаляем папку cache, если она существует
  if DirectoryExists(CachePath) then
    DeleteDirectory(CachePath);

  // Создаём файл cache
  if not FileExists(CachePath) then begin
    try
      with TFileStream.Create(CachePath, fmCreate) do
        Free;
      FileSetAttr(CachePath, faReadOnly);
    except
      // Игнорируем ошибки (например, недостаток прав)
    end;
  end;
end;


// Сообщение в трее
procedure TFMain.ShowTrayHint(const Title, Message: string);
begin
  // Показываем иконку в трее
  TrayIcon1.Show;

  // Опционально: уведомление в трее
  TrayIcon1.BalloonHint := Message;
  TrayIcon1.BalloonTitle := Title;
  TrayIcon1.ShowBalloonHint;
end;

// Выбор файла эмулятора
procedure TFMain.Button1Click(Sender: TObject);
var
  Path: string;
begin
  Path := Trim(LabeledEdit1.Text);
  if Path <> '' then begin
    Path := ExtractFilePath(Path);
    if DirectoryExists(Path) then OpenDialog1.InitialDir := Path;
  end;
  if OpenDialog1.Execute then
  begin
    LabeledEdit1.Text := OpenDialog1.FileName;
    WriteRegValue(REG_PATH_EMULATOR, OpenDialog1.FileName);
  end;
end;

procedure TFMain.Button2Click(Sender: TObject);
begin
end;

procedure TFMain.Button3Click(Sender: TObject);
begin
  // Если эмулятор уже запущен - выходим
  if FEmulatorRunning then
    Exit;

  // Финальная проверка путей
  LabeledEdit1.Text := Trim(LabeledEdit1.Text);
  if (LabeledEdit1.Text = '') or not FileExists(LabeledEdit1.Text) then
  begin
    MessageDlg('Ошибка',
         'Файл эмулятора не найден!' + sLineBreak +
         'Укажите правильный путь к dnplayer.exe',
         mtError, [mbOK], 0);
    Button1.Click; // Предлагаем исправить
    Exit;
  end;

  // Запускаем эмулятор
  if StartEmulator(LabeledEdit1.Text) then
  begin
    // Close; // Раскомментировать, если нужно закрыть лаунчер после запуска
  end;
end;

procedure TFMain.Button4Click(Sender: TObject);
begin
  Timer9.Enabled := False;
  Timer10.Enabled := False;
  FClickClose := True;
  Close;
end;

procedure TFMain.Button5Click(Sender: TObject);
var
  FolderPath: string;
begin
  FolderPath := Trim(LabeledEdit2.Text);

  if FolderPath = '' then
  begin
    MessageDlg('Предупреждение', 'Общая папка не определена', mtWarning, [mbOK], 0);
    Exit;
  end;

  if DirectoryExists(FolderPath) then
    ShellExecute(0, 'open', 'explorer.exe', PChar(FolderPath), nil, SW_SHOWNORMAL)
  else
  begin
    MessageDlg('Предупреждение', 'Папка "' + FolderPath + '" не существует', mtWarning, [mbOK], 0);
  end;
end;

procedure TFMain.CheckBox1Change(Sender: TObject);
begin
  if not CheckBox1.Checked then begin
    Timer3.Enabled := False; // Останавливаем
    Label2.Font.Color := clDefault;
    ClearClipboard;
  end;
end;

procedure TFMain.FormClose(Sender: TObject; var CloseAction: TCloseAction);
var
  FolderPath: string;
begin
  // Останавливаем таймер при закрытии
  Timer1.Enabled := False;
  Timer3.Enabled := False; // Останавливаем контроль времени
  Timer5.Enabled := False;
  Timer6.Enabled := False;
  Timer8.Enabled := False;

  Label2.Font.Color := clDefault;

  if FEmulatorRunning then
  begin
    Hide;
    if not CloseMainWindowByPID(FEmulatorPID) then
    begin
      // Если не нашли окно, используем запасной вариант
      MessageDlg('Внимание',
           'Не удалось корректно закрыть эмулятор, или эмулятор слишком долго закрывается.' + sLineBreak +
           'Закройте его вручную.',
           mtWarning, [mbOK], 0);
    end;
  end;

  Timer2.Enabled := False;

  // Проверяем общую папку на наличие файлов
  FolderPath := Trim(LabeledEdit2.Text);
  FSharedFiles := ScanSharedFolder(FolderPath);
  if FSharedFiles.Count > 0 then begin
    MessageDlg('Предупреждение',
       'ВНИМАНИЕ!' + sLineBreak +
       'В общей папке эмулятора "' + FolderPath + '" остались файлы.' + sLineBreak +
       'Количество файлов: ' + IntToStr(FSharedFiles.Count),
       mtWarning, [mbOK], 0);
  end;

  // Сохранение параметров
  WriteRegValue(REG_PATH_EMULATOR, Trim(LabeledEdit1.Text));
  WriteRegValue(REG_EMULATOR_AUTORUN, BoolToStr(CheckBox4.Checked));
  WriteRegValue(REG_MAX_AUTORUN, BoolToStr(CheckBox3.Checked));
  WriteRegValue(REG_CLOSE_WITH_EMULATOR, BoolToStr(CheckBox2.Checked));
end;

procedure TFMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FEmulatorRunning and not FClickClose then begin
    CanClose := False; // Не даем закрыть приложение
    MinimizeToTray;    // Вместо этого сворачиваем в трей
  end;
  FClickClose := False;
end;

procedure TFMain.FormCreate(Sender: TObject);
var
  EmulatorPath, SharedFolderPath: String;
  MR: TModalResult;
  ConfigPath: string;
begin
  FIsLDPlayer := False;
  FEmulatorPID := 0;
  FEmulatorRunning := False;
  FClickClose := False;

  // Читаем настройки из реестра
  EmulatorPath := Trim(ReadRegValue(REG_PATH_EMULATOR));
  CheckBox4.Checked := StrToBoolDef(ReadRegValue(REG_EMULATOR_AUTORUN), False);
  CheckBox3.Checked := StrToBoolDef(ReadRegValue(REG_MAX_AUTORUN), False);
  CheckBox2.Checked := StrToBoolDef(ReadRegValue(REG_CLOSE_WITH_EMULATOR), True);

  // Проверяем путь к эмулятору - ПЕРВОСТЕПЕННАЯ важность
  if (EmulatorPath = '') or not FileExists(EmulatorPath) then EmulatorPath := GetLDPlayerPath;
  if EmulatorPath = '' then begin
    MessageDlg('Информация',
         'Укажите файл эмулятора (dnplayer.exe)',
         mtInformation, [mbOK], 0);
    Button1.Click; // Принудительно вызываем диалог выбора файла
    if LabeledEdit1.Text = '' then Application.Terminate;
  end
  else
  begin
    LabeledEdit1.Text := EmulatorPath;
  end;

  ConfigPath := ExtractFilePath(LabeledEdit1.Text) + 'vms\config\leidian0.config';

  LDConfig := LoadLDConfig(ConfigPath);

  // Включаем режим ADB
  if not GetADBDebug(LDConfig) then begin
    SetADBDebug(ConfigPath, LDConfig, True);
  end;

  // Блокировка рекламы
  BlockLDPlayerAds;

  // Проверяем общую папку - ВТОРОСТЕПЕННАЯ важность
  SharedFolderPath := GetSharedPictures(LDConfig);
  LabeledEdit2.Text := SharedFolderPath;

  FAutoRun := CheckBox4.Checked; // Автоматический запуск эмулятора

  // Проверяем общую папку на наличие файлов
  FSharedFiles := ScanSharedFolder(LabeledEdit2.Text);
  if FSharedFiles.Count > 0 then begin
    MR := MessageDlg('Вопрос',
       'ВНИМАНИЕ!' + sLineBreak +
       'В общей папке эмулятора "' + LabeledEdit2.Text + '" обнаружены файлы.' + sLineBreak +
       'Эти файлы доступны для MAX!' + sLineBreak +
       'Количество файлов: ' + IntToStr(FSharedFiles.Count) + sLineBreak +
       'Все равно запустить эмулятор?',
       mtConfirmation, [mbYes, mbNo, mbCancel], 0);
    if MR = mrCancel then begin
      Application.Terminate;
      Exit;
    end;
    if MR = mrNo then begin
      FAutoRun := False;
      WindowState := wsNormal;
    end;
  end;

  LoadSplashImage;

  TrayIcon1.Icon := Application.Icon;

  if FAutoRun then
    Timer4.Enabled := True;

end;

procedure TFMain.FormDblClick(Sender: TObject);
begin

end;

procedure TFMain.FormDestroy(Sender: TObject);
begin
  FreeLDConfig(LDConfig);
  FSharedFiles.Free;
end;

procedure TFMain.MenuItem1Click(Sender: TObject);
begin
  RestoreFromTray;
end;

procedure TFMain.MenuItem2Click(Sender: TObject);
begin
  Button4Click(Sender);
end;

procedure TFMain.Timer10Timer(Sender: TObject);
var
  Step: Integer;
  Command, OutStr, PCLPath: string;
  OK, Process: Boolean;
begin
  Timer10.Enabled := False;

  Step := Timer10.Tag;
  Process := True;

  PCLPath := ExtractFilePath(Application.ExeName) + 'PCL.apk';
  if (Step < 4) and not FileExists(PCLPath) then Step := 4;

  case Step of
    0: begin
      // Шаг 0: Определение текущего лаунчера
      Command := '-s ' + ADBDevice + ' shell dumpsys activity activities | grep mResumedActivity';
      RunADB(Command, OutStr);
      // Если стоит стандартный лаунчер LDPlayer
      if Pos(LDP_LAUNCHER, OutStr) > 0 then
        Timer10.Tag := 1 // Переходим к установке PCL
      else
        Timer10.Tag := 4; // Уже стоит другой лаунчер, пропускаем установку
    end;

    1: begin
      // Шаг 1: Устанавливаем PCL
      Command := '-s ' + ADBDevice + ' install -r "' + PCLPath + '"';
      RunADB(Command, OutStr);
      OutStr := LowerCase(OutStr);
      if (Pos('success', OutStr) > 0) or (Pos('installed', OutStr) > 0) then
        Timer10.Tag := 2
      else
        Timer10.Tag := 4;
    end;

    2: begin
      // Шаг 2: Удаляем LD лаунчер
      Command := '-s ' + ADBDevice + ' shell pm uninstall --user 0 ' + LDP_LAUNCHER;
      RunADB(Command, OutStr);
      Timer10.Tag := 4;
    end;

    4: begin
      // Шаг 4: Запуск Max
      if CheckBox3.Checked then begin
        Command := '-s ' + ADBDevice + ' shell am start -n ' + MAX_PACKAGE + '/' + MAX_ACTIVITY;
        RunADB(Command, OutStr);
        OK := (Pos('error', OutStr) = 0) and (Pos('unknow', OutStr) = 0);
        if not OK then ShowTrayHint('Ошибка', 'Не удалось запустить MAX.');
        Timer10.Tag := 5;
      end;
    end;

    5: begin
      // Шаг 5: Удаляем магазин
      Command := '-s ' + ADBDevice + ' shell pm uninstall --user 0 com.android.ld.appstore';
      RunADB(Command, OutStr);
      Process := False;
      Timer10.Tag := 0;
    end;

    else Process := False;
  end;

  if Process then Timer10.Enabled := True;
end;

procedure TFMain.Timer1Timer(Sender: TObject);
var
  Closed: Boolean;
begin
  if FEmulatorRunning then
  begin
    // Если LDPlayer - проверяем и по окну и по процессу
    if FIsLDPlayer then
      Closed := not IsProcessRunning(FEmulatorPID) or (FindWindow('LDPlayerMainFrame', nil) = 0)
    else
      Closed := not IsProcessRunning(FEmulatorPID); // Только по процессу

    if Closed then
    begin
      // Процесс завершился
      FEmulatorRunning := False;
      FIsLDPlayer := False;
      FEmulatorPID := 0;
      Timer1.Enabled := False;
      Timer2.Enabled := False;
      Timer3.Enabled := False;
      Timer5.Enabled := False;
      Timer6.Enabled := False;
      Timer8.Enabled := False;

      Timer9.Enabled := False;
      Timer9.Tag := 0;
      Timer10.Enabled := False;
      Timer10.Tag := 0;

      //CheckBox1.Checked := False;
      Label2.Font.Color := clDefault;

      FreeAndNil(FSplashStretchBitmap);

      if CheckBox2.Checked then begin
        FClickClose := True;
        Close; // Закрываем лаунчер
        Exit;
      end;

      // Разблокируем кнопку
      Button3.Enabled := True;
      Button3.Caption := 'Запустить эмулятор';

      LabeledEdit1.ReadOnly := False;
      Button1.Enabled := True;

      // Восстанавливаем окно когда эмулятор закрылся
      RestoreFromTray;

    end;
  end;
end;

procedure TFMain.Timer2Timer(Sender: TObject);
begin
  if FEmulatorRunning and not IsClipboardEmpty then begin
    if not CheckBox1.Checked then begin
      ClearClipboard;
      ShowTrayHint('Внимание', 'Буфер обмена отключен.');
    end else begin
      if not Timer3.Enabled then begin
        ShowTrayHint(
          'Внимание',
          'В буфер обмена помещены данные.' + sLineBreak +
          'MAX имеет к ним доступ!'
        );
        Timer3.Enabled := True;  // Запускаем контроль
      end;
    end;
  end;
end;

procedure TFMain.Timer3Timer(Sender: TObject);
var
  T: Integer;
  S: string;
begin
  Timer3.Enabled := False;
  if CheckBox1.Checked and not IsClipboardEmpty then
  begin
    T := Timer3.Interval div 60000;
    if T > 0 then begin
      S := IntToStr(T) + ' минут.';
    end else begin
      T := Timer3.Interval div 1000;
      S := IntToStr(T) + ' секунд.';
    end;
    Label2.Font.Color := clRed;
    ShowTrayHint(
      'Внимание',
      'Буфер обмена содержит данные и доступен для MAX более ' + S + sLineBreak +
      'Не забывайте отключать опцию после использования!'
    );
    Timer3.Enabled := True;
  end;
end;

procedure TFMain.Timer4Timer(Sender: TObject);
begin
  Timer4.Enabled := False;
  Button3.Click;
end;

procedure TFMain.Timer5Timer(Sender: TObject);
var
  i: Integer;
  H: HWND;
begin
  // Ищем по классам окон
  for i := 0 to High(AD_CLASSES) do
  begin
    H := FindWindow(PChar(AD_CLASSES[i]), nil);
    if H <> 0 then
    begin
      PostMessage(H, WM_CLOSE, 0, 0);
    end;
  end;
end;

procedure TFMain.Timer6Timer(Sender: TObject);
var
  MainWnd, RenderWnd: HWND;
  DC: HDC;
  MainRect: TRect;
  DrawRect: Boolean;
  ProgressRect: TRect;
  ProgressBrush: HBRUSH;
  BitmapDC: HDC;
  OldFont, NewFont: HFONT;
  TextStr: String;
begin
  MainWnd := FindWindow('LDPlayerMainFrame', nil);
  if MainWnd <> 0 then
  begin
    FIsLDPlayer := True;

    // Ожидание момента загрузки эмулятора
    RenderWnd := FindWindowEx(MainWnd, 0, 'RenderWindow', nil);
    if (RenderWnd <> 0) and IsWindowVisible(RenderWnd) then begin
      Timer6.Enabled := False;
      FreeAndNil(FSplashStretchBitmap);

      // Запускаем мониторинг ADB
      ADBPath := ExtractFilePath(LabeledEdit1.Text) + 'adb.exe';
      ADBDevice := Format('127.0.0.1:%d', [ADB_PORT]);
      Timer9.Tag := 0;
      Timer9.Enabled := True;

      Exit;
    end;

    Windows.GetClientRect(MainWnd, MainRect); // Получаем размеры клиентской области

    // Проверяем размеры
    if (MainRect.Width <= 0) or (MainRect.Height <= 0) then
    begin
      // Окно еще не инициализировано, ждем следующий тик
      Exit;
    end;

    DC := GetWindowDC(MainWnd);
    if DC <> 0 then
    begin

      try
        // Заливаем основную область черным (с отступом от заголовка)
        ProgressRect := MainRect;
        ProgressRect.Left := 1;
        ProgressRect.Right := MainRect.Right - 1;
        ProgressRect.Top := 30; // Отступ от верха для системного заголовка
        ProgressRect.Bottom := MainRect.Bottom - 52; // Отступ снизу для прогрессбара
        DrawRect := True;

        if FSplashBitmap <> nil then
        begin
          // Масштабируем картинку
          if FSplashStretchBitmap = nil then begin
            DrawRect := not PrepareSplashForWindow(ProgressRect.Width, ProgressRect.Height);
          end else DrawRect := False;

          if not DrawRect then begin
            // Вывод картинки
            BitmapDC := CreateCompatibleDC(DC);
            SelectObject(BitmapDC, FSplashStretchBitmap.Handle);
            BitBlt(DC, ProgressRect.Left, ProgressRect.Top,
                   ProgressRect.Width, ProgressRect.Height,
                   BitmapDC, 0, 0, SRCCOPY);
            DeleteDC(BitmapDC);
          end;
        end;

        if DrawRect then begin
          ProgressBrush := CreateSolidBrush(RGB(0, 0, 0));
          FillRect(DC, ProgressRect, ProgressBrush);
          DeleteObject(ProgressBrush);

          // Установить белый цвет текста
          SetTextColor(DC, RGB(255, 255, 255));
          SetBkMode(DC, TRANSPARENT); // Прозрачный фон

          NewFont := CreateFont(48, 0, 0, 0, FW_BOLD, 0, 0, 0,
                                DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                                CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
                                DEFAULT_PITCH, 'Arial');
          OldFont := SelectObject(DC, NewFont);

          // Текст "Loading..."
          TextStr := 'Loading...';
          TextOut(DC, ProgressRect.Right div 2 - 95, ProgressRect.Bottom div 2, PChar(TextStr), Length(TextStr));

          // Вернуть старый шрифт
          SelectObject(DC, OldFont);
          DeleteObject(NewFont);
        end;
      finally
        ReleaseDC(MainWnd, DC);
      end;
    end;
  end;
end;

procedure TFMain.Timer7Timer(Sender: TObject);
var
  MainWnd: HWND;
begin
  if FEmulatorRunning then
  begin
    // Пытаемся поменять заголовок и иконку окна эмулятора
    MainWnd := FindMainWindowByPID(FEmulatorPID);
    if MainWnd <> 0 then
    begin
      Timer7.Enabled := False;
      SetWindowText(MainWnd, PChar('MAX'));
      ChangeEmulatorIcon(MainWnd);
    end;
  end else begin
    Timer7.Enabled := False;
  end;
end;

procedure TFMain.Timer8Timer(Sender: TObject);
var
  Files: TStringList;
  F: string;
  i: Integer;
begin
  Timer8.Enabled := False;

  Files := ScanSharedFolder(LabeledEdit2.Text);

  F := '';
  for i := 0 to Files.Count - 1 do begin
    if FSharedFiles.IndexOf(Files[i]) = -1 then begin
      F := ExtractFileName(Files[i]);
      Break;
    end;
  end;

  if F <> '' then begin
    ShowTrayHint(
      'Внимание',
      'В общей папке обнаружен файл:' + sLineBreak + '"' + F + '"'
    );
  end;

  if (Files.Count <> FSharedFiles.Count) or (F <> '') then begin
    FSharedFiles.Free;
    FSharedFiles := Files;
  end else begin
    Files.Free;
  end;

  if FEmulatorRunning then Timer8.Enabled := True;
end;

procedure TFMain.Timer9Timer(Sender: TObject);
const
  Errors: array of string = (
    '',
    'Не удалось подключиться к ADB.',
    'Устройство не найдено в adb devices.',
    'Android не загрузился.'
  );
var
  Step: Integer;
  Commands: array of string;
  Command, OutStr: string;
  OK: Boolean;
begin
  Timer9.Enabled := False;

  // Формируем последовательность команд
  Commands := [
    // 0. Инициализация
    '',
    // 1. Подключение
    'connect ' + ADBDevice,
    // 2. Проверка устройства
    'devices',
    // 3. Проверка загрузки Android
    '-s ' + ADBDevice + ' shell getprop sys.boot_completed'
  ];

  Step := Timer9.Tag;
  if Step < Length(Commands) then begin
    OK := True;

    // Очередная команда
    Command := Commands[Step];
    if Command <> '' then begin
      RunADB(Command, OutStr);
      //ShowTrayHint('DEBUG Step ' + IntToStr(Step), OutStr);

      // Проверяем ответ ADB
      case Step of
        1: OK := (Pos('connected to', OutStr) > 0) or (Pos('already connected', OutStr) > 0);
        2: OK := Pos(ADBDevice + #9'device', OutStr) > 0;
        3: OK := Trim(OutStr) = '1';
      end;
    end;

    // Неудача - повторяем попытку
    if not OK then begin
      if FADBRetryCount >= 30 then begin
        if (Step < Length(Errors)) and (Errors[Step] <> '') then ShowTrayHint('Ошибка', Errors[Step]);
        Exit;
      end;
      Inc(FADBRetryCount);
    end else // Успех - переходим к следующей команде
    begin
      FADBRetryCount := 0;
      Timer9.Tag := Step + 1;
    end;

    Timer9.Enabled := True;
  end else begin
    // Переходим к выполнению команд
    Timer10.Tag := 0;
    Timer10.Enabled := True;
  end;

end;

procedure TFMain.TrayIcon1Click(Sender: TObject);
begin
  // Если окно скрыто - показываем его
  if not Visible then
    RestoreFromTray
  else
    MinimizeToTray;
end;

function TFMain.ReadRegValue(ValueName: String): String;
var
   Reg: TRegistry;
begin
   Result := '';
   Reg := TRegistry.Create;
   try
     Reg.RootKey := HKEY_CURRENT_USER;
     if Reg.OpenKey(REG_KEY, False) then
     begin
       Result := Reg.ReadString(ValueName);
       Reg.CloseKey;
     end;
   finally
     Reg.Free;
   end;
end;

procedure TFMain.WriteRegValue(ValueName, ValueData: String);
var
   Reg: TRegistry;
begin
   Reg := TRegistry.Create;
   try
     Reg.RootKey := HKEY_CURRENT_USER;
     if Reg.OpenKey(REG_KEY, True) then
     begin
       Reg.WriteString(ValueName, ValueData);
       Reg.CloseKey;
     end;
   finally
     Reg.Free;
   end;
end;

function TFMain.StartEmulator(const ExePath: string): Boolean;
var
  AProcess: TProcess;
begin
  Result := False;

  // Очищаем буфер обмена
  if not CheckBox1.Checked then
    ClearClipboard;

  try
    AProcess := TProcess.Create(nil);
    try
      AProcess.Executable := ExePath;
      AProcess.Options := [poNoConsole];
      AProcess.Execute;

      // Сохраняем PID и запускаем мониторинг
      FEmulatorPID := AProcess.ProcessID;
      FEmulatorRunning := True;

      // Блокируем кнопку запуска
      Button3.Enabled := False;
      Button3.Caption := 'Эмулятор запущен (PID: ' + IntToStr(FEmulatorPID) + ')';

      LabeledEdit1.ReadOnly := True;
      Button1.Enabled := False;

      // Запускаем мониторинг
      Timer1.Enabled := True;
      Timer2.Enabled := True;
      Timer5.Enabled := True;
      Timer6.Enabled := True;
      Timer7.Enabled := True;
      Timer8.Enabled := True;

      // Сворачиваем лаунчер в трей при успешном запуске
      MinimizeToTray;

      Result := True;
    finally
      AProcess.Free;
    end;
  except
    on E: Exception do
    begin
      ShowMessage('Ошибка запуска: ' + E.Message);
      Result := False;
    end;
  end;
end;

function TFMain.IsClipboardEmpty: Boolean;
begin
  Result := (Clipboard.FormatCount = 0);
end;

procedure TFMain.ClearClipboard;
begin
  if OpenClipboard(0) then
  begin
    EmptyClipboard;
    CloseClipboard;
  end;
end;

// Функция загрузки стартового изображения
procedure TFMain.LoadSplashImage;
var
  Jpeg: TJPEGImage;
begin
  FSplashBitmap := nil;
  FSplashStretchBitmap := nil;

  if not FileExists(SplashFileName) then
    Exit;

  try
    Jpeg := TJPEGImage.Create;
    try
      Jpeg.LoadFromFile(SplashFileName);
      FSplashBitmap := TBitmap.Create;
      FSplashBitmap.Assign(Jpeg);
    finally
      Jpeg.Free;
    end;
  except
    // В случае ошибки оставляем FSplashBitmap = nil
  end;
end;

// Масштабирование фонового изображения
function TFMain.PrepareSplashForWindow(W, H: Integer): Boolean;
var
  Rect: TRect;
  TempJpeg: TJPEGImage;
begin
  Result := True;
  if FSplashBitmap = nil then begin
    Result := False;
    Exit;
  end;
  FSplashStretchBitmap := TBitmap.Create;
  try
    FSplashStretchBitmap.PixelFormat := pf24bit;
    FSplashStretchBitmap.Width := W;
    FSplashStretchBitmap.Height := H;
    Rect.Left := 0;
    Rect.Top := 0;
    Rect.Width := W;
    Rect.Height := H;
    FSplashStretchBitmap.Canvas.StretchDraw(Rect, FSplashBitmap);

    // Это костыль!
    TempJpeg := TJPEGImage.Create;
    try
      TempJpeg.Assign(FSplashStretchBitmap);  // В JPEG
      FSplashStretchBitmap.Assign(TempJpeg);  // Обратно в Bitmap
    finally
      TempJpeg.Free;
    end;

  except
    Result := False;
  end;
end;

// Свернуть в трей
procedure TFMain.MinimizeToTray;
begin
  // Прячем окно приложения
  Application.Minimize;
  Hide;

  ShowTrayHint('Информация', 'Лаунчер MAX свернут в трей.');
end;

// Восстановить из трея
procedure TFMain.RestoreFromTray;
begin
  // Показываем окно приложения
  Show;
  WindowState := wsNormal;
  Application.Restore;
  BringToFront;

  // Убираем иконку из трея
  TrayIcon1.Hide;
end;

// Меняем иконку эмулятора
procedure TFMain.ChangeEmulatorIcon(MainWnd: HWND);
var
  IconHandle: HICON;
begin
  // Получаем иконку из нашего приложения
  IconHandle := Application.Icon.Handle;

  if IconHandle <> 0 then
  begin
    SendMessage(MainWnd, WM_SETICON, ICON_BIG, LPARAM(IconHandle));
    SendMessage(MainWnd, WM_SETICON, ICON_SMALL, LPARAM(IconHandle));

    // Обновляем панель задач
    SetWindowPos(MainWnd, 0, 0, 0, 0, 0,
                 SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_FRAMECHANGED);
  end;
end;

end.

