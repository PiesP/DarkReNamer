//! Native controls, menus and dialogs.

crate::i18n::catalog! {
    text {
        SaveFolderNotRetained = ("현재 저장 폴더를 유지하지 못했습니다. 폴더를 다시 선택하세요.", "The current save folder was not retained; navigate to it again.", "現在の保存先フォルダーを保持できませんでした。フォルダーを再度選択してください。");
        MenuFile = ("파일(&F)", "&File", "ファイル(&F)");
        MenuEdit = ("편집(&E)", "&Edit", "編集(&E)");
        MenuView = ("보기(&V)", "&View", "表示(&V)");
        MenuTransform = ("변환(&T)", "&Transform", "変換(&T)");
        MenuHelp = ("도움말(&H)", "&Help", "ヘルプ(&H)");
        MenuExport = ("내보내기(&X)", "E&xport", "エクスポート(&X)");
        MenuTargetFolder = ("대상 폴더(&D)", "&Destination folder", "移動先フォルダー(&D)");
        MenuTheme = ("테마(&T)", "&Theme", "テーマ(&T)");
        MenuLanguage = ("언어(&L) · 다음 실행부터", "&Language · next startup", "言語(&L) · 次回起動から");
        MenuText = ("텍스트(&T)", "&Text", "テキスト(&T)");
        MenuRemoval = ("삭제·추출(&R)", "&Remove and extract", "削除・抽出(&R)");
        MenuNumber = ("번호(&N)", "&Number", "連番(&N)");
        MenuExtension = ("확장자(&E)", "&Extension", "拡張子(&E)");
        MenuFolderName = ("폴더명 사용(&F)", "Use &folder name", "フォルダー名を使用(&F)");
        MenuRecovery = ("복구(&R)", "&Recovery", "復旧(&R)");
        MenuExit = ("종료(&Q)\tAlt+F4", "E&xit\tAlt+F4", "終了(&Q)\tAlt+F4");
        MenuRemoveSelected = ("선택 항목을 목록에서 제거\tDelete", "Remove selected from list\tDelete", "選択項目を一覧から削除\tDelete");
        MenuThemeSystem = ("시스템 설정(&S)", "&System", "システム設定(&S)");
        MenuThemeLight = ("밝게(&L)", "&Light", "ライト(&L)");
        MenuThemeDark = ("어둡게(&D)", "&Dark", "ダーク(&D)");
        MenuAppearance = ("모양 설정(&A)...", "&Appearance settings...", "外観設定(&A)...");
        MenuPreviewDetails = ("선택 항목 진단(&I)...", "Selected item &details...", "選択項目の詳細(&I)...");
        MenuExportRecovery = ("복구 데이터 내보내기...", "Export recovery data...", "復旧データをエクスポート...");
        MenuDiscardStaged = ("시작되지 않은 작업 기록 삭제...", "Discard unstarted operation record...", "未開始の操作記録を削除...");
        MenuRecoveryStatus = ("복구 상태 및 문제 확인...", "Recovery status and issues...", "復旧状態と問題を確認...");
        MenuLanguageSystem = ("시스템 언어", "System language", "システム言語");
        MenuLanguageKorean = ("한국어", "한국어", "한국어");
        MenuLanguageEnglish = ("English", "English", "English");
        MenuLanguageJapanese = ("日本語", "日本語", "日本語");
        DialogShowDetails = ("상세 정보 표시", "Show details", "詳細を表示");
        DialogHideDetails = ("상세 정보 숨기기", "Hide details", "詳細を非表示");
        DialogFullInfoTitle = ("전체 이름과 경로", "Full names and paths", "名前とパスの全体");
        DialogFullInfoTooLong = ("전체 정보가 안전한 표시 길이를 초과했습니다.", "The full details exceed the safe display length.", "詳細が安全な表示文字数を超えています。");
        DialogFullInfoNul = ("전체 정보에 NUL 문자가 포함되어 있습니다.", "The full details contain a NUL character.", "詳細に NUL 文字が含まれています。");
        DialogFullInfoOutOfMemory = ("전체 정보를 표시할 메모리가 부족합니다.", "Not enough memory to display the full details.", "詳細を表示するためのメモリが不足しています。");
        DialogCopyAll = ("전체 복사(&C)", "&Copy all", "すべてコピー(&C)");
        DialogClose = ("닫기", "Close", "閉じる");
        DialogConfirm = ("확인", "OK", "確認");
        DialogCancel = ("취소", "Cancel", "キャンセル");
        DialogCopyFailureTitle = ("DarkReNamer - 복사 실패", "DarkReNamer - Copy failed", "DarkReNamer - コピー失敗");
        DialogFilePickerFailureTitle = ("DarkReNamer - 파일 선택 실패", "DarkReNamer - File selection failed", "DarkReNamer - ファイル選択失敗");
        DialogTargetPickerFailureTitle = ("DarkReNamer - 대상 폴더 선택 실패", "DarkReNamer - Destination folder selection failed", "DarkReNamer - 移動先フォルダーの選択失敗");
        DialogSaveFailureTitle = ("DarkReNamer - 저장 실패", "DarkReNamer - Save failed", "DarkReNamer - 保存失敗");
        DialogExportFailureTitle = ("DarkReNamer - 진단 내보내기 실패", "DarkReNamer - Diagnostic export failed", "DarkReNamer - 診断データのエクスポート失敗");
        DialogImportFailureTitle = ("DarkReNamer - 불러오기 실패", "DarkReNamer - Import failed", "DarkReNamer - 読み込み失敗");
        DialogMoveDestinationTitle = ("모든 파일을 이동할 대상 폴더 선택", "Select destination folder for all files", "すべてのファイルの移動先フォルダーを選択");
        DialogSaveNamesTitle = ("파일명 저장", "Save names", "ファイル名を保存");
        DialogSavePathsTitle = ("경로명 저장", "Save paths", "パスを保存");
        DialogImportNamesTitle = ("바꿀 파일 이름 불러오기", "Import replacement names", "変更後のファイル名を読み込む");
        DialogImportPathsTitle = ("파일에서 경로목록 읽어 추가하기", "Add paths from file", "ファイルからパス一覧を追加");
        DialogExportFolderTitle = ("복구 저널 원본을 저장할 폴더 선택", "Select folder for recovery journal originals", "復旧ジャーナル原本の保存先フォルダーを選択");
        DialogSaveLocationTitle = ("DarkReNamer - 저장 위치 확인", "DarkReNamer - Verify save location", "DarkReNamer - 保存先を確認");
        DialogExportLocationTitle = ("DarkReNamer - 진단 내보내기 위치 확인", "DarkReNamer - Verify diagnostic export location", "DarkReNamer - 診断データのエクスポート先を確認");
        DialogLoadFilesTitle = ("이름 붙일 파일 불러오기", "Select files to rename", "名前を変更するファイルを選択");
        DialogFilterTextFiles = ("텍스트 파일", "Text Files", "テキストファイル");
        DialogFilterAllFiles = ("모든 파일", "All Files", "すべてのファイル");
        DialogSaveNoReplace = ("기존 파일은 덮어쓰지 않습니다. 사용하지 않는 새 파일 이름을 선택해 주세요.", "Existing files are never replaced. Choose a new, unused file name.", "既存のファイルは上書きしません。未使用の新しいファイル名を選択してください。");
        DialogInputChanged = ("입력값이 읽는 동안 변경되어 적용하지 않았습니다.", "The input changed while it was being read; nothing was applied.", "読み込み中に入力が変わったため、適用しませんでした。");
        AppearanceTitle = ("DarkReNamer - 모양 설정 (미리보기)", "DarkReNamer - Appearance settings (preview)", "DarkReNamer - 外観設定 (プレビュー)");
        AppearanceGroupDensity = ("명령 버튼 배치", "Command button layout", "コマンドボタンの配置");
        AppearanceDensityAuto = ("자동 (권장)", "Automatic (recommended)", "自動 (推奨)");
        AppearanceDensitySpacious = ("여유 있게", "Spacious", "ゆったり");
        AppearanceDensityCompact = ("촘촘하게", "Compact", "コンパクト");
        AppearanceDensityMenuOnly = ("메뉴만", "Menu only", "メニューのみ");
        AppearanceGroupEmphasis = ("변경 후 이름 강조", "Proposed name emphasis", "変更後の名前の強調");
        AppearanceEmphasisSubtle = ("약하게", "Subtle", "弱");
        AppearanceEmphasisStandard = ("표준", "Standard", "標準");
        AppearanceEmphasisStrong = ("강하게", "Strong", "強");
        AppearanceSeparators = ("명령 버튼 그룹 구분선 표시", "Show command group separators", "コマンド群の区切り線を表示");
        AppearanceTint = ("변경 후 이름 셀 배경 강조", "Tint proposed-name cells", "変更後の名前セルの背景を強調");
        AppearanceEmptySafety = ("빈 목록에서 안전 안내 표시", "Show safety guidance in an empty list", "空の一覧に安全案内を表示");
        AppearanceForcedColors = ("고대비가 활성화되어 변경 후 이름의 글자와 셀 배경은 시스템 색상을 사용합니다.", "High contrast is active. Proposed-name text and cell backgrounds use system colors.", "ハイコントラストが有効です。変更後の名前とセル背景にはシステム色を使用します。");
        AppearanceReset = ("기본값으로 복원", "Restore defaults", "既定値に戻す");
        AppearanceSave = ("저장", "Save", "保存");
        AppearanceSettingsTitle = ("DarkReNamer - 모양 설정", "DarkReNamer - Appearance settings", "DarkReNamer - 外観設定");
        AppearanceWaitUntilIdle = ("진행 중인 작업이나 확인 대화상자를 마친 뒤 모양 설정을 열어 주세요.", "Finish the current operation or confirmation dialog before opening appearance settings.", "進行中の操作または確認ダイアログを終えてから外観設定を開いてください。");
        AppearanceStateChangedBeforeOpen = ("모양 설정 창을 준비하는 동안 작업 상태가 바뀌어 창을 열지 않았습니다.", "The operation state changed while preparing appearance settings, so the window was not opened.", "外観設定を準備中に操作状態が変わったため、ウィンドウを開きませんでした。");
        AppearanceActivationFailed = ("모양 설정 창을 활성화하지 못했습니다. 현재 작업에는 영향이 없습니다.", "Could not activate the appearance settings window. Current work is unaffected.", "外観設定ウィンドウをアクティブにできませんでした。現在の作業には影響しません。");
        AppearanceStateChangedDuringActivation = ("모양 설정 창을 활성화하는 동안 작업 상태가 바뀌어 창을 닫았습니다.", "The operation state changed while activating appearance settings, so the window was closed.", "外観設定をアクティブにする間に操作状態が変わったため、ウィンドウを閉じました。");
        DispatchReadOnlyTitle = ("DarkReNamer - 읽기 전용", "DarkReNamer - Read only", "DarkReNamer - 読み取り専用");
        DispatchMutationTitle = ("DarkReNamer - 변경 중", "DarkReNamer - Changes in progress", "DarkReNamer - 変更処理中");
        DispatchPreviewTitle = ("DarkReNamer - 선택 항목 진단", "DarkReNamer - Selected item details", "DarkReNamer - 選択項目の詳細");
        DispatchTargetTitle = ("DarkReNamer - 대상 폴더 지정", "DarkReNamer - Set destination folder", "DarkReNamer - 移動先フォルダーを指定");
        DispatchAboutTitle = ("DarkReNamer 정보", "About DarkReNamer", "DarkReNamer について");
        DispatchImportLimitTitle = ("DarkReNamer - 가져오기 한도", "DarkReNamer - Import limit", "DarkReNamer - 読み込み制限");
        DispatchImportNamesTitle = ("DarkReNamer - 이름 가져오기", "DarkReNamer - Import names", "DarkReNamer - ファイル名を読み込む");
        PromptReplaceExplanation = ("이름에 들어있는 문자열을 바꿉니다.", "Replace text in each name.", "名前に含まれる文字列を置換します。");
        PromptFrom = ("를", "Find", "検索");
        PromptTo = ("으로", "Replace with", "置換後");
        PromptPrefixExplanation = ("이름의 앞에 지정한 문자열을 붙여줍니다.", "Add the specified text before each name.", "指定した文字列を名前の先頭に追加します。");
        PromptSuffixExplanation = ("이름의 뒤에 지정한 문자열을 붙여줍니다.", "Add the specified text after each name.", "指定した文字列を名前の末尾に追加します。");
        PromptTextToAdd = ("붙일 문자열", "Text to add", "追加する文字列");
        PromptExtensionAddExplanation = ("확장자를 뒤에 붙입니다.", "Append an extension.", "拡張子を末尾に追加します。");
        PromptExtensionToAdd = ("붙일 확장자", "Extension to add", "追加する拡張子");
        PromptExtensionReplaceExplanation = ("확장자를 바꿔 줍니다.", "Replace the extension.", "拡張子を置き換えます。");
        PromptReplacementExtension = ("바꿀 확장자", "New extension", "新しい拡張子");
        PromptPadDigitsExplanation = ("숫자부분의 자리수를 맞춰 0을 붙입니다.", "Pad number groups with zeros to the chosen width.", "数字部分を指定した桁数までゼロで埋めます。");
        PromptDigits = ("자리수", "Digits", "桁数");
        PromptPadLast = ("제일 뒷번호 맞춤", "Pad last number", "最後の数字を揃える");
        PromptPadFirst = ("제일 앞번호 맞춤", "Pad first number", "最初の数字を揃える");
        PromptSequenceExplanation = ("붙일 숫자의 자리수와 시작값을 지정합니다.", "Choose the width and starting value for appended numbers.", "追加する連番の桁数と開始値を指定します。");
        PromptStartValue = ("시작값", "Starting value", "開始値");
        PromptSequenceSuffix = ("이름뒤에 번호붙임", "Append number to name", "名前の末尾に番号を追加");
        PromptSequencePrefix = ("이름앞에 번호붙임", "Prepend number to name", "名前の先頭に番号を追加");
        PromptSequenceFolderSuffix = ("폴더별로 뒤 번호붙임", "Append number per folder", "フォルダーごとに末尾へ番号を追加");
        PromptSequenceFolderPrefix = ("폴더별로 앞 번호붙임", "Prepend number per folder", "フォルダーごとに先頭へ番号を追加");
        PromptDeletePositionExplanation = ("지정위치를 삭제합니다.(첫글자는 1번째)", "Delete characters at the selected positions (first character is 1).", "指定した位置の文字を削除します (先頭は 1 文字目)。");
        PromptFromPosition = ("번째부터", "From position", "開始位置");
        PromptToPosition = ("번째까지", "To position", "終了位置");
        PromptDeleteFromStart = ("앞에서부터 삭제", "Delete from start", "先頭から削除");
        PromptDeleteFromEnd = ("제일 뒤부터 삭제", "Delete from end", "末尾から削除");
        PromptDeleteDelimitedExplanation = ("지정된 문자로 묶인 부분을 삭제합니다.", "Delete text between the specified delimiters.", "指定した区切り文字で囲まれた部分を削除します。");
        PromptStartDelimiter = (":시작문자", "Start delimiter", "開始文字");
        PromptEndDelimiter = (":끝문자", "End delimiter", "終了文字");
        PromptSortExplanation = ("정렬 기준 설정", "Choose sort order", "並べ替え基準を選択");
        PromptSortNameAsc = ("파일 이름에 따라 오름차순", "File name ascending", "ファイル名の昇順");
        PromptSortNameDesc = ("파일 이름에 따라 내림차순", "File name descending", "ファイル名の降順");
        PromptSortPathAsc = ("현재 전체 경로에 따라 오름차순", "Current full path ascending", "現在のフルパスの昇順");
        PromptSortPathDesc = ("현재 전체 경로에 따라 내림차순", "Current full path descending", "現在のフルパスの降順");
        PromptSortSizeAsc = ("실제 파일 크기에 따라 오름차순", "Actual file size ascending", "実際のファイルサイズの昇順");
        PromptSortSizeDesc = ("실제 파일 크기에 따라 내림차순", "Actual file size descending", "実際のファイルサイズの降順");
        PromptSortModifiedAsc = ("수정한 시각에 따라 오름차순", "Modified time ascending", "更新日時の昇順");
        PromptSortModifiedDesc = ("수정한 시각에 따라 내림차순", "Modified time descending", "更新日時の降順");
        PromptSortCreatedAsc = ("만든 시각에 따라 오름차순", "Created time ascending", "作成日時の昇順");
        PromptSortCreatedDesc = ("만든 시각에 따라 내림차순", "Created time descending", "作成日時の降順");
        DispatchInvalidDigits = ("자리수 입력이 잘못되었습니다.", "Invalid number of digits.", "桁数の入力が正しくありません。");
        DispatchInvalidNumber = ("음수값이나 잘못된 값이 입력되었습니다.", "A negative or invalid value was entered.", "負の値または無効な値が入力されました。");
        DispatchInvalidRange = ("시작점이 끝점보다 뒤에 있습니다.", "The starting position is after the ending position.", "開始位置が終了位置より後です。");
        DispatchDeleteFromEnd = ("맨 뒤에서부터 삭제할때는 '~까지'만 필요합니다.", "To delete from the end, enter only the ending position.", "末尾から削除する場合は終了位置のみ入力してください。");
        DispatchInvalidDelimiters = ("시작/끝 문자가 정확하게 지정되지 않았습니다.", "Start and end delimiters were not specified correctly.", "開始文字と終了文字が正しく指定されていません。");
        DispatchPreviewOnly = ("미리보기 · ‘변경 적용’ 전에는 파일을 수정하지 않습니다.", "Preview · Files are unchanged until Apply changes.", "プレビュー · 「変更を適用」までファイルは変更されません。");
        DispatchReadOnlyGuidance = ("복구 잠금 상태에서는 진단 저널 내보내기, 테마 변경, 정보 보기, 종료만 사용할 수 있습니다.", "While recovery is locked, only diagnostic journal export, appearance/language settings, About and Exit are available.", "復旧がロックされている間は、診断ジャーナルのエクスポート、外観・言語設定、情報表示、終了のみ使用できます。");
        DispatchMutationGuidance = ("파일 변경이 끝날 때까지 테마 변경, 정보 보기와 종료 요청만 사용할 수 있습니다.", "Until file changes finish, only appearance/language settings, About and Exit are available.", "ファイルの変更が終わるまでは、外観・言語設定、情報表示、終了のみ使用できます。");
        DispatchTargetFilesOnly = ("대상 폴더 지정은 일반 파일만 있는 목록에서 사용할 수 있습니다. 폴더 항목을 목록에서 제거한 뒤 다시 시도하세요.", "Destination folder selection requires a list of regular files only. Remove folder items from the list and try again.", "移動先フォルダーの指定は通常のファイルだけの一覧で使用できます。フォルダー項目を一覧から削除して再試行してください。");
        DispatchImportStale = ("가져오기 중 목록 또는 작업 상태가 바뀌어 결과를 적용하지 않았습니다.", "The list or operation state changed during import; results were not applied.", "読み込み中に一覧または操作状態が変わったため、結果を適用しませんでした。");
        DispatchImportExceedsList = ("경로 목록이 남은 10,000개 한도를 초과해 제한된 수만 처리합니다.", "The path list exceeds the remaining 10,000-item limit; only a bounded number will be processed.", "パス一覧が残り 10,000 件の上限を超えたため、制限内の件数のみ処理します。");
        DispatchDialogStale = ("파일 대화상자가 열린 동안 목록 또는 작업 상태가 바뀌어 결과를 적용하지 않았습니다.", "The list or operation state changed while the file dialog was open; nothing was applied.", "ファイルダイアログを開いている間に一覧または操作状態が変わったため、適用しませんでした。");
        DispatchPromptStale = ("입력창이 열린 동안 목록 또는 작업 상태가 바뀌어 입력을 적용하지 않았습니다.", "The list or operation state changed while the input dialog was open; input was not applied.", "入力ダイアログを開いている間に一覧または操作状態が変わったため、入力を適用しませんでした。");
        DragDropLimitTitle = ("DarkReNamer - 추가 한도", "DarkReNamer - Add limit", "DarkReNamer - 追加上限");
        DragDropReadFailureTitle = ("DarkReNamer - 경로 읽기 실패", "DarkReNamer - Path read failed", "DarkReNamer - パスの読み込み失敗");
        DragDropItemAndPathLimit = ("선택 항목이 남은 개수와 UTF-16 경로 용량 안전 한도를 초과해 제한된 수만 처리합니다.", "The selection exceeds both the remaining item count and safe UTF-16 path capacity; only a bounded number will be processed.", "選択項目が残り件数と UTF-16 パス容量の安全上限を超えたため、制限内の件数のみ処理します。");
        DragDropItemLimit = ("선택 항목이 남은 개수 한도를 초과해 제한된 수만 처리합니다.", "The selection exceeds the remaining item count; only a bounded number will be processed.", "選択項目が残り件数の上限を超えたため、制限内の件数のみ処理します。");
        DragDropPathLimit = ("선택 경로가 UTF-16 경로 용량 안전 한도를 초과해 이미 확인한 항목만 처리합니다.", "Selected paths exceed the safe UTF-16 path capacity; only already checked items will be processed.", "選択したパスが UTF-16 パス容量の安全上限を超えたため、確認済みの項目のみ処理します。");

        TextIoFileTooLarge = ("가져오기 파일이 2 MiB 한도를 초과합니다", "The import file exceeds the 2 MiB limit", "読み込みファイルが 2 MiB の上限を超えています");
    }
    messages {
        prompt_manual_current(current: &dyn std::fmt::Display) = ("{current} 를", "Rename {current} to", "{current} を次の名前に変更");
        dialog_prompt_failure(detail: &dyn std::fmt::Display) = ("입력창을 처리하지 못했습니다. {detail}", "The input dialog could not be processed. {detail}", "入力ダイアログを処理できませんでした。{detail}");
        dialog_copy_failure(error: &dyn std::fmt::Display) = ("클립보드에 복사하지 못했습니다: {error}", "Could not copy to the clipboard: {error}", "クリップボードにコピーできませんでした: {error}");
        dialog_copy_failure_retry(error: &dyn std::fmt::Display) = ("클립보드에 복사하지 못했습니다: {error}\n다시 시도할 수 있습니다.", "Could not copy to the clipboard: {error}\nYou can try again.", "クリップボードにコピーできませんでした: {error}\n再試行できます。");
        dialog_input_too_long(length: usize, limit: usize) = ("입력값이 너무 깁니다(UTF-16 {length}/{limit}자).", "Input is too long (UTF-16 units: {length}/{limit}).", "入力が長すぎます (UTF-16 単位: {length}/{limit})。");
        dialog_file_picker_failure(error: &dyn std::fmt::Display) = ("파일 선택을 완료하지 못했습니다: {error}\n다시 파일을 선택해 주세요.", "Could not complete file selection: {error}\nSelect the files again.", "ファイル選択を完了できませんでした: {error}\nもう一度選択してください。");
        dialog_target_picker_failure(error: &dyn std::fmt::Display) = ("대상 폴더를 선택하지 못했습니다: {error}", "Could not select a destination folder: {error}", "移動先フォルダーを選択できませんでした: {error}");
        dialog_save_picker_failure(error: &dyn std::fmt::Display) = ("저장 대화상자를 열지 못했습니다: {error}", "Could not open the Save dialog: {error}", "保存ダイアログを開けませんでした: {error}");
        dialog_export_picker_failure(error: &dyn std::fmt::Display) = ("복구 저널 저장 폴더를 열지 못했습니다: {error}", "Could not open the recovery journal destination folder: {error}", "復旧ジャーナルの保存先フォルダーを開けませんでした: {error}");
        dialog_import_picker_failure(error: &dyn std::fmt::Display) = ("불러올 파일을 선택하지 못했습니다: {error}", "Could not select a file to import: {error}", "読み込むファイルを選択できませんでした: {error}");
        dialog_save_location_failure(error: &dyn std::fmt::Display) = ("선택한 저장 위치를 안전하게 고정하지 못했습니다. 다른 위치를 선택해 주세요.\n{error}", "Could not safely bind the selected save location. Choose a different location.\n{error}", "選択した保存先を安全に固定できませんでした。別の場所を選んでください。\n{error}");
        dialog_export_location_failure(error: &dyn std::fmt::Display) = ("선택한 저장 폴더를 안전하게 고정하지 못했습니다. 다른 폴더를 선택해 주세요.\n{error}", "Could not safely bind the selected export folder. Choose another folder.\n{error}", "選択した保存フォルダーを安全に固定できませんでした。別のフォルダーを選んでください。\n{error}");
        appearance_open_failure(error: &dyn std::fmt::Display) = ("모양 설정 창을 열지 못했습니다. 현재 작업에는 영향이 없습니다: {error}", "Could not open appearance settings. Current work is unaffected: {error}", "外観設定を開けませんでした。現在の作業には影響しません: {error}");
        appearance_apply_failure(error: &dyn std::fmt::Display) = ("모양 설정을 화면에 적용하지 못했습니다. 파일 작업에는 영향이 없습니다: {error}", "Could not apply appearance settings to the window. File operations are unaffected: {error}", "外観設定を画面に適用できませんでした。ファイル操作には影響しません: {error}");
        list_view_exact_size(details: &dyn std::fmt::Display, size: &dyn std::fmt::Display) = ("{details}\n정확한 크기: {size}", "{details}\nExact size: {size}", "{details}\n正確なサイズ: {size}");
        drag_drop_unreadable_paths(count: usize) = ("드롭한 항목 중 {count}개의 경로를 읽지 못해 제외했습니다. 정상적으로 읽은 경로만 추가 대상으로 검사합니다.", "Could not read paths for {count} dropped items, so they were excluded. Only readable paths will be considered for adding.", "ドロップした項目のうち {count} 件のパスを読めず除外しました。読み取れたパスのみ追加候補として確認します。");
        dispatch_details_failure(error: &dyn std::fmt::Display) = ("전체 정보를 표시하지 못했습니다: {error}", "Could not display full details: {error}", "詳細を表示できませんでした: {error}");
        dispatch_target_validation_failure(error: &dyn std::fmt::Display) = ("선택한 대상 폴더를 로컬 NTFS 안전 범위에서 확인하지 못했습니다. 목록은 변경되지 않았습니다. 다른 폴더를 선택해 주세요. ({error})", "Could not validate the selected destination within the safe local NTFS scope. The list is unchanged. Choose another folder. ({error})", "選択した移動先フォルダーを安全なローカル NTFS 範囲で確認できませんでした。一覧は変更されていません。別のフォルダーを選んでください。({error})");
        dispatch_save_failure(error: &dyn std::fmt::Display) = ("파일을 저장하지 못했습니다: {error}", "Could not save the file: {error}", "ファイルを保存できませんでした: {error}");
        dispatch_import_start_failure(error: &dyn std::fmt::Display) = ("가져오기 작업을 시작하지 못했습니다: {error}", "Could not start the import: {error}", "読み込みを開始できませんでした: {error}");
        dispatch_import_read_failure(error: &dyn std::fmt::Display) = ("가져오기 파일을 읽지 못했습니다: {error}", "Could not read the import file: {error}", "読み込みファイルを読めませんでした: {error}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::i18n::{Language, with_language};

    #[test]
    fn visible_language_control_and_safety_messages_follow_the_active_ui_language() {
        for (language, language_label, read_only_phrase, no_replace_phrase) in [
            (
                Language::Korean,
                "언어(&L) · 다음 실행부터",
                "복구 잠금",
                "덮어쓰지",
            ),
            (
                Language::English,
                "&Language · next startup",
                "recovery is locked",
                "never replaced",
            ),
            (
                Language::Japanese,
                "言語(&L) · 次回起動から",
                "復旧がロック",
                "上書きしません",
            ),
        ] {
            with_language(language, || {
                assert_eq!(Text::MenuLanguage.get(), language_label);
                assert!(
                    Text::DispatchReadOnlyGuidance
                        .get()
                        .contains(read_only_phrase)
                );
                assert!(Text::DialogSaveNoReplace.get().contains(no_replace_phrase));
                assert!(!Text::MenuLanguageKorean.get().is_empty());
                assert!(!Text::MenuLanguageEnglish.get().is_empty());
                assert!(!Text::MenuLanguageJapanese.get().is_empty());
            });
        }
    }

    #[test]
    fn formatted_display_guidance_preserves_values_and_actionable_scope() {
        for language in [Language::Korean, Language::English, Language::Japanese] {
            with_language(language, || {
                let path = r"C:\사진\旅行\one.txt";
                let failure = dialog_save_location_failure(&path);
                assert!(failure.contains(path));
                assert!(failure.contains('\n'));
                let limit = dialog_input_too_long(256, 255);
                assert!(limit.contains("256"));
                assert!(limit.contains("255"));
                let excluded = drag_drop_unreadable_paths(7);
                assert!(excluded.contains('7'));
            });
        }
    }
}
