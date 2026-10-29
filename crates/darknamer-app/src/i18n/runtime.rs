//! Native operation, startup and recovery guidance.

crate::i18n::catalog! {
    text {
        RelativePath = ("상대 경로는 사용할 수 없습니다.", "Relative paths cannot be used.", "相対パスは使用できません。");
        InvalidWindowsName = ("Windows에서 사용할 수 없는 이름입니다.", "This name cannot be used on Windows.", "この名前は Windows では使用できません。");
        MissingSource = ("원본 항목을 찾을 수 없습니다.", "The source item could not be found.", "元の項目が見つかりません。");
        SourceKindChanged = ("원본 항목 종류가 변경되었습니다.", "The source item type has changed.", "元の項目の種類が変更されました。");
        ReparseSource = ("재분석 지점은 변경할 수 없습니다.", "Reparse points cannot be changed.", "再解析ポイントは変更できません。");
        DuplicateDestination = ("중복되는 대상 이름이 있습니다.", "Two items have the same destination name.", "複数の項目の変更先名が重複しています。");
        DuplicateSource = ("중복되는 원본 항목이 있습니다.", "The source item is duplicated.", "元の項目が重複しています。");
        DestinationOccupied = ("대상 이름이 이미 사용 중입니다.", "The destination name is already in use.", "変更先の名前はすでに使用されています。");
        CrossParent = ("다른 폴더로 이동할 수 없습니다.", "Cannot move to a different folder.", "別のフォルダーには移動できません。");
        CrossVolume = ("다른 볼륨으로 이동할 수 없습니다.", "Cannot move to another volume.", "別のボリュームには移動できません。");
        DirectoryMoveUnsupported = ("폴더 이동은 아직 지원하지 않습니다.", "Moving folders is not supported yet.", "フォルダーの移動にはまだ対応していません。");
        SourceOverlap = ("상위/하위 항목을 함께 변경할 수 없습니다.", "A parent and its child cannot be changed together.", "親項目と子項目は同時に変更できません。");
        PathTooDeep = ("경로의 폴더 깊이가 안전 한도를 초과했습니다.", "The path exceeds the safe folder-depth limit.", "パスのフォルダー階層が安全上の制限を超えています。");
        CaseSensitiveParent = ("대소문자 구분 폴더는 아직 지원하지 않습니다.", "Case-sensitive folders are not supported yet.", "大文字と小文字を区別するフォルダーにはまだ対応していません。");
        UnsupportedWindowsPath = ("네트워크 또는 지원하지 않는 경로입니다.", "This network or other path is unsupported.", "ネットワークパス、または対応していないパスです。");
        UnsupportedFilesystem = ("NTFS 파일 시스템만 지원합니다.", "Only the NTFS file system is supported.", "NTFS ファイルシステムのみ対応しています。");
        BackendPlan = ("파일 시스템을 안전하게 확인하지 못했습니다.", "The file system could not be checked safely.", "ファイルシステムを安全に確認できませんでした。");
        PlanInspection = ("계획 검사", "Plan inspection", "実行計画の検査");
        ExecutionPreparation = ("실행 준비", "Execution preparation", "実行準備");
        FileMutation = ("파일 변경", "File change", "ファイル変更");
        CancelledBeforeMutation = ("파일 변경을 시작하기 전에 취소했습니다.", "Cancelled before changing files.", "ファイル変更を開始する前に取り消しました。");
        StaleSource = ("원본 항목이 계획 이후 변경되었습니다.", "The source item changed after planning.", "元の項目が計画後に変更されました。");
        StaleParent = ("부모 폴더가 계획 이후 변경되었습니다.", "The parent folder changed after planning.", "親フォルダーが計画後に変更されました。");
        DestinationChanged = ("대상 이름이 계획 이후 변경되었습니다.", "The destination name changed after planning.", "変更先の名前が計画後に変更されました。");
        TemporaryExhausted = ("안전한 임시 이름을 확보하지 못했습니다.", "Could not reserve a safe temporary name.", "安全な一時名を確保できませんでした。");
        InvalidSchedule = ("안전한 실행 순서를 만들지 못했습니다.", "Could not create a safe execution order.", "安全な実行順序を作成できませんでした。");
        UnauthorizedMove = ("계획된 이동이 허용된 안전 범위를 벗어났습니다.", "The planned move exceeds the permitted safety scope.", "計画された移動は許可された安全範囲を超えています。");
        MutationCompleted = ("파일 변경을 완료했습니다.", "File changes completed.", "ファイルの変更が完了しました。");
        CancelledAndRestored = ("요청에 따라 변경을 취소하고 원래 상태로 복원했습니다.", "Cancelled as requested and restored the original state.", "要求に従って変更を取り消し、元の状態に戻しました。");
        RecoveryRequiredAfterCancellation = ("취소 요청 후 상태 확인과 복구가 필요합니다. 적용이 잠겼습니다.", "The cancelled operation needs a state check and recovery. Apply is locked.", "取消し後に状態確認と復旧が必要です。適用はロックされています。");
        MutationCancelled = ("요청에 따라 변경을 취소했습니다.", "File changes were cancelled as requested.", "要求に従ってファイル変更を取り消しました。");
        ExportTargetExists = ("기존 파일은 덮어쓰지 않습니다. 사용하지 않는 새 파일 이름을 선택해 주세요.", "Existing files are never overwritten. Choose an unused new file name.", "既存のファイルは上書きしません。未使用の新しいファイル名を選んでください。");
        MissingLocalAppData = ("LOCALAPPDATA 환경 변수를 찾을 수 없습니다", "The LOCALAPPDATA environment variable is missing", "LOCALAPPDATA 環境変数が見つかりません");
        JournalRootNotAbsolute = ("저널 경로가 절대 경로가 아닙니다", "The journal path is not absolute", "ジャーナルのパスが絶対パスではありません");
        ConflictingJournals = ("active 저널과 candidate 저널을 동시에 발견했습니다. 자동 복구와 폐기를 중단하고 두 상태를 보존합니다.", "Both active and candidate journals were found. Automatic recovery and discard are stopped; both states are retained.", "active と candidate の両ジャーナルが見つかりました。自動復旧と破棄を中止し、両方の状態を保持します。");
        NoRetainedActive = ("보존된 active 저널 정보가 없습니다.", "No retained active journal information is available.", "保持された active ジャーナルの情報がありません。");
        RecoverPrevious = ("이전 변경 복구", "Recover previous changes", "前回の変更を復旧");
        RecoveryConfirmTitle = ("DarkReNamer - 이전 변경 복구 확인", "DarkReNamer - Confirm recovery", "DarkReNamer - 復旧の確認");
        RecoveryConfirmQuestion = ("이전 실행에서 중단된 이름 변경을 복구하시겠습니까?", "Recover name changes interrupted in the previous run?", "前回の実行で中断された名前変更を復旧しますか？");
        RecoveryConfirmDetail = ("복구를 선택하면 보존된 저널과 현재 파일 신원을 다시 검증한 뒤 필요한 역방향 이름 변경을 수행합니다. 취소하면 어떤 파일도 변경하지 않고 복구 잠금을 유지합니다.", "Recover checks the retained journal and current file identities again before reversing changes as needed. Cancel changes no files and keeps recovery locked.", "復旧を選ぶと、保持されたジャーナルと現在のファイル識別情報を再検証して必要な逆方向の名前変更を行います。キャンセルするとファイルは変更されず、復旧ロックが維持されます。");
        RecoveryDeferredTitle = ("DarkReNamer - 복구 보류", "DarkReNamer - Recovery deferred", "DarkReNamer - 復旧を保留");
        RecoveryStateChanged = ("확인 중 복구 상태가 변경되어 어떤 파일도 변경하지 않았습니다.", "Recovery state changed during confirmation; no files were changed.", "確認中に復旧状態が変わったため、ファイルは変更していません。");
        RecoveryRejectedTitle = ("DarkReNamer - 복구 거부", "DarkReNamer - Recovery refused", "DarkReNamer - 復旧を拒否");
        RecoveryCompletedTitle = ("DarkReNamer - 복구 완료", "DarkReNamer - Recovery completed", "DarkReNamer - 復旧完了");
        RecoveryNeedsReviewTitle = ("DarkReNamer - 복구 확인 필요", "DarkReNamer - Recovery needs review", "DarkReNamer - 復旧状態の確認が必要");
        RecoveryCannotStart = ("현재 상태에서는 active 저널 복구를 시작할 수 없습니다.", "Recovery of the active journal cannot start in the current state.", "現在の状態では active ジャーナルの復旧を開始できません。");
        NoActiveToRecover = ("복구할 active 저널이 없습니다.", "There is no active journal to recover.", "復旧する active ジャーナルがありません。");
        RecoveredButCleanupFailed = ("이전 변경을 검증하고 복구했지만 저널 정리가 완료되지 않았습니다.", "Previous changes were verified and recovered, but journal cleanup did not finish.", "前回の変更を検証・復旧しましたが、ジャーナルの削除は完了しませんでした。");
        RecoveredAndCleaned = ("이전 변경을 안전하게 복구하고 저널을 정리했습니다.", "Previous changes were recovered safely and the journal was removed.", "前回の変更を安全に復旧し、ジャーナルを削除しました。");
        VerifiedButCleanupFailed = ("파일 상태를 안전하게 확인했지만 완료된 저널을 정리하지 못했습니다.", "File state was checked safely, but the completed journal could not be removed.", "ファイルの状態を安全に確認しましたが、完了したジャーナルを削除できませんでした。");
        VerifiedAndCleaned = ("파일 상태를 안전하게 확인하고 완료된 저널을 정리했습니다.", "File state was checked safely and the completed journal was removed.", "ファイルの状態を安全に確認し、完了したジャーナルを削除しました。");
        NoRetainedHandle = ("보존된 저널 핸들이 없어 원본을 안전하게 복사할 수 없습니다.", "No retained journal handle is available to copy the original safely.", "保持されたジャーナルハンドルがなく、元のデータを安全にコピーできません。");
        RecoveryExportUnavailableTitle = ("DarkReNamer - 진단 내보내기 불가", "DarkReNamer - Cannot export diagnostics", "DarkReNamer - 診断をエクスポートできません");
        RecoveryExportStateChanged = ("진단 내보내기 창이 열린 동안 복구 상태가 바뀌어 원본을 복사하지 않았습니다.", "Recovery state changed while the diagnostic export window was open; the original was not copied.", "診断のエクスポート画面を開いている間に復旧状態が変わったため、元のデータはコピーしていません。");
        RecoveryExportCompleteTitle = ("DarkReNamer - 진단 내보내기 완료", "DarkReNamer - Diagnostic export completed", "DarkReNamer - 診断のエクスポート完了");
        RecoveryExportPartialTitle = ("DarkReNamer - 진단 내보내기 일부 실패", "DarkReNamer - Some diagnostic exports failed", "DarkReNamer - 一部の診断エクスポートに失敗");
        DiscardNotAllowed = ("현재 상태에서는 활성화 전 저널을 폐기할 수 없습니다. 복구 상태를 다시 확인해 주세요.", "The pre-activation journal cannot be discarded in the current state. Check recovery status again.", "現在の状態では有効化前のジャーナルを破棄できません。復旧状態を再確認してください。");
        DiscardRejectedTitle = ("DarkReNamer - 폐기 거부", "DarkReNamer - Discard refused", "DarkReNamer - 破棄を拒否");
        DiscardConfirmTitle = ("DarkReNamer - 활성화 전 계획 폐기", "DarkReNamer - Discard pre-activation plan", "DarkReNamer - 有効化前の計画を破棄");
        DiscardConfirmQuestion = ("활성화 전 실행 계획을 폐기하시겠습니까?", "Discard the pre-activation execution plan?", "有効化前の実行計画を破棄しますか？");
        DiscardConfirmDetail = ("파일 변경은 시작되지 않았습니다. 폐기하면 새 적용을 다시 사용할 수 있습니다.", "No file changes began. Discarding it allows Apply again.", "ファイル変更は始まっていません。破棄すると適用を再び使用できます。");
        DiscardButton = ("계획 폐기", "Discard plan", "計画を破棄");
        DiscardStateChanged = ("확인 중 복구 상태가 변경되어 폐기를 중단했습니다.", "Recovery state changed during confirmation; discard was stopped.", "確認中に復旧状態が変わったため、破棄を中止しました。");
        DiscardCancelledTitle = ("DarkReNamer - 폐기 취소", "DarkReNamer - Discard cancelled", "DarkReNamer - 破棄を取消し");
        NoJournalToDiscard = ("폐기할 저널이 없습니다.", "There is no journal to discard.", "破棄するジャーナルがありません。");
        OtherRecoveryAfterDiscard = ("저널 폐기 후 다른 복구 상태가 관찰되어 적용 잠금을 유지합니다.", "Another recovery state was observed after journal discard; Apply remains locked.", "ジャーナルの破棄後に別の復旧状態が確認されたため、適用ロックを維持します。");
        RecoveryStateReviewTitle = ("DarkReNamer - 복구 상태 확인 필요", "DarkReNamer - Review recovery state", "DarkReNamer - 復旧状態の確認が必要");
        DiscardedNoChange = ("활성화 전 실행 계획을 폐기했습니다. 파일은 변경되지 않았습니다.", "The pre-activation execution plan was discarded. No files were changed.", "有効化前の実行計画を破棄しました。ファイルは変更されていません。");
        DiscardedApplyAvailable = ("활성화 전 실행 계획을 폐기했습니다. 파일은 변경되지 않았으며 새 적용을 사용할 수 있습니다.", "The pre-activation execution plan was discarded. No files were changed, and Apply is available.", "有効化前の実行計画を破棄しました。ファイルは変更されず、適用を使用できます。");
        DiscardCompleteTitle = ("DarkReNamer - 폐기 완료", "DarkReNamer - Discard completed", "DarkReNamer - 破棄完了");
        RecoveryCollisionStatus = ("상태: active와 candidate가 동시에 관찰되어 자동 복구와 폐기를 중단했습니다.", "Status: Both active and candidate journals were found; automatic recovery and discard are stopped.", "状態: active と candidate の両ジャーナルが見つかり、自動復旧と破棄を中止しました。");
        RecoveryLockedStatus = ("상태: 복구 잠금", "Status: recovery locked", "状態: 復旧ロック中");
        NoRecoveryJournalStatus = ("상태: 복구 저널 없음", "Status: no recovery journal", "状態: 復旧ジャーナルなし");
        CompleteIntentOnly = ("완전한 Intent-only", "complete Intent-only", "完全な Intent-only");
        EmptyCandidate = ("빈 candidate", "empty candidate", "空の candidate");
        UndiscardableCandidate = ("폐기할 수 없는 candidate", "candidate cannot be discarded", "破棄できない candidate");
        ExportRecoveryAvailable = ("가능한 작업: 복구 데이터 내보내기", "Available action: export recovery data", "実行可能: 復旧データのエクスポート");
        ConfirmRecoveryAvailable = ("시작 시 확인 가능: 이전 변경의 명시적 복구", "Available at startup: explicitly recover previous changes", "起動時に選択可能: 前回の変更の明示的な復旧");
        DiscardUnusedJournalAvailable = ("가능한 작업: 시작되지 않은 작업 기록 삭제", "Available action: delete the record of an operation that never began", "実行可能: 開始されなかった操作の記録を削除");
        RecoveryStatusTitle = ("DarkReNamer - 복구 상태", "DarkReNamer - Recovery status", "DarkReNamer - 復旧状態");
        DiscardFailedTitle = ("DarkReNamer - 폐기 실패", "DarkReNamer - Discard failed", "DarkReNamer - 破棄に失敗");
        ImportReading = ("가져오기 파일을 읽는 중입니다. 취소를 요청할 수 있습니다...", "Reading the import file. You can request cancellation...", "インポートするファイルを読み取っています。取消しを要求できます...");
        ApplyBlockedTitle = ("DarkReNamer - 적용 차단", "DarkReNamer - Apply blocked", "DarkReNamer - 適用をブロック");
        FixDisplayedDestination = ("표시된 행의 대상 이름 문제를 수정해 주세요.", "Correct the destination-name problem shown in the row.", "表示された行の変更先名の問題を修正してください。");
        ApplyBusy = ("복구 또는 다른 변경이 진행 중이어서 적용할 수 없습니다.", "Apply is unavailable while recovery or another change is in progress.", "復旧または別の変更が進行中のため適用できません。");
        PlanSummaryMismatch = ("실행 계획 요약이 내부 실행 단계와 일치하지 않습니다. 파일 변경은 시작되지 않았습니다.", "The plan summary does not match the internal execution steps. No file changes began.", "実行計画の要約と内部の実行手順が一致しません。ファイル変更は始まっていません。");
        NothingToChange = ("변경할 항목이 없습니다.", "There are no items to change.", "変更する項目がありません。");
        ApplyFullDetailsTitle = ("DarkReNamer - 변경 예시 전체 정보", "DarkReNamer - Full change-example details", "DarkReNamer - 変更例の詳細");
        ApplyConfirmTitle = ("DarkReNamer - 안전한 적용 확인", "DarkReNamer - Confirm safe Apply", "DarkReNamer - 安全な適用の確認");
        ApplyConfirmQuestion = ("계획된 파일 변경을 적용하시겠습니까?", "Apply the planned file changes?", "計画されたファイル変更を適用しますか？");
        ApplyButton = ("변경 적용", "Apply changes", "変更を適用");
        ApplyFullDetailsButton = ("예시 전체 정보 · 복사", "Full example details · Copy", "変更例の詳細・コピー");
        ApplyStateChanged = ("확인 중 목록 또는 작업 상태가 바뀌어 실행 계획을 적용하지 않았습니다.", "The list or operation state changed during confirmation; the plan was not applied.", "確認中に一覧または操作状態が変わったため、実行計画は適用していません。");
        ApplyCancelledTitle = ("DarkReNamer - 적용 취소", "DarkReNamer - Apply cancelled", "DarkReNamer - 適用を取消し");
        ApplyNotStarted = ("적용하지 않았습니다. 미리보기를 계속 편집할 수 있습니다.", "Nothing was applied. You can continue editing the preview.", "適用していません。プレビューの編集を続けられます。");
        ApplyRecoveryChanged = ("확인 중 복구 또는 다른 작업 상태가 바뀌어 실행 계획을 적용하지 않았습니다.", "Recovery or another operation changed during confirmation; the plan was not applied.", "確認中に復旧または別の操作の状態が変わったため、実行計画は適用していません。");
        ApplyListChanged = ("확인 후 목록이 변경되었습니다. 다시 계획하고 확인해 주세요.", "The list changed after confirmation. Plan and confirm again.", "確認後に一覧が変わりました。計画と確認をやり直してください。");
        JournalCleanupFailedTitle = ("DarkReNamer - 저널 정리 실패", "DarkReNamer - Journal cleanup failed", "DarkReNamer - ジャーナルの削除に失敗");
        PreApplyRefused = ("적용 전 검사에서 중단 · 파일 변경 없음. 오류를 해결한 뒤 다시 적용하세요.", "Stopped during pre-Apply checks; no files were changed. Resolve the error and Apply again.", "適用前の検査で中断しました。ファイルは変更されていません。問題を解決して再度適用してください。");
        ExecutionRefusedTitle = ("DarkReNamer - 실행 거부", "DarkReNamer - Execution refused", "DarkReNamer - 実行を拒否");
        OutcomeMismatch = ("완료 결과를 목록과 일치시키지 못했습니다. 저널을 보존하고 적용을 잠급니다.", "The completed result could not be reconciled with the list. The journal is retained and Apply is locked.", "完了結果を一覧と照合できませんでした。ジャーナルを保持し、適用をロックします。");
        ReviewNeededTitle = ("DarkReNamer - 확인 필요", "DarkReNamer - Review needed", "DarkReNamer - 確認が必要");
        ExecutionFailedTitle = ("DarkReNamer - 실행 실패", "DarkReNamer - Execution failed", "DarkReNamer - 実行に失敗");
        RecoveryNeededTitle = ("DarkReNamer - 복구 필요", "DarkReNamer - Recovery required", "DarkReNamer - 復旧が必要");
        PlanningProgress = ("파일 시스템을 확인하고 실행 계획을 만들고 있습니다...", "Checking the file system and preparing the execution plan...", "ファイルシステムを確認し、実行計画を作成しています...");
        PlannerCrashed = ("planning worker가 비정상 종료되었습니다. 파일 변경은 시작되지 않았습니다.", "The planning worker terminated unexpectedly. No file changes began.", "計画ワーカーが異常終了しました。ファイル変更は始まっていません。");
        PlanningErrorTitle = ("DarkReNamer - 계획 오류", "DarkReNamer - Planning error", "DarkReNamer - 計画エラー");
        PlanningCancelled = ("파일 변경 계획을 취소했습니다.", "File-change planning was cancelled.", "ファイル変更の計画を取り消しました。");
        PlannerInternalError = ("planning worker 내부 오류가 발생했습니다. 파일 변경은 시작되지 않았습니다.", "The planning worker encountered an internal error. No file changes began.", "計画ワーカーで内部エラーが発生しました。ファイル変更は始まっていません。");
        PlannerNoResult = ("planning worker가 결과를 전달하지 못했습니다. 파일 변경은 시작되지 않았습니다.", "The planning worker did not return a result. No file changes began.", "計画ワーカーから結果が届きませんでした。ファイル変更は始まっていません。");
        PlanningNoResultTitle = ("DarkReNamer - 계획 결과 없음", "DarkReNamer - No planning result", "DarkReNamer - 計画結果なし");
        ApplyLockedTitle = ("DarkReNamer - 적용 잠김", "DarkReNamer - Apply locked", "DarkReNamer - 適用をロック");
        ExecutionOrderProgress = ("실행 순서를 준비하고 있습니다...", "Preparing the execution order...", "実行順序を準備しています...");
        ReflectingResult = ("파일 처리 결과를 목록에 반영하고 있습니다...", "Updating the list with the file-operation result...", "ファイル処理の結果を一覧に反映しています...");
        FinalizingResult = ("변경 결과 확정 중 · 이 단계는 취소할 수 없습니다", "Finalizing changes; this step cannot be cancelled", "変更結果を確定中です。この段階は取り消せません");
        ApplyWorkerCrashed = ("적용 worker가 비정상 종료되었습니다. 남은 저널을 다음 시작에서 복구하도록 적용을 잠급니다.", "The Apply worker terminated unexpectedly. Apply is locked so the retained journal can be recovered at the next startup.", "適用ワーカーが異常終了しました。残されたジャーナルを次回起動時に復旧できるよう、適用をロックします。");
        WorkerErrorTitle = ("DarkReNamer - worker 오류", "DarkReNamer - Worker error", "DarkReNamer - ワーカーエラー");
        ApplyWorkerInternalError = ("적용 worker 내부 오류가 발생했습니다. 남은 저널을 다음 시작에서 복구하도록 적용을 잠급니다.", "The Apply worker encountered an internal error. Apply is locked so the retained journal can be recovered at the next startup.", "適用ワーカーで内部エラーが発生しました。残されたジャーナルを次回起動時に復旧できるよう、適用をロックします。");
        ApplyWorkerNoTerminal = ("적용 worker가 terminal 결과를 전달하지 못했습니다. 다음 시작 복구를 위해 적용을 잠급니다.", "The Apply worker did not return a terminal result. Apply is locked for recovery at the next startup.", "適用ワーカーから最終結果が届きませんでした。次回起動時の復旧のため適用をロックします。");
        WorkerNoResultTitle = ("DarkReNamer - worker 결과 없음", "DarkReNamer - No worker result", "DarkReNamer - ワーカー結果なし");
        RecoveryLockedForReview = ("복구 확인이 필요해 적용을 잠갔습니다. 복구 상태 메뉴에서 저널을 확인하세요.", "Apply is locked pending recovery review. Check the journal in the Recovery Status menu.", "復旧の確認が必要なため適用をロックしました。「復旧状態」メニューでジャーナルを確認してください。");
        IconShutdownProgress = ("아이콘 정보 조회를 마치는 중입니다. 완료되면 창이 닫힙니다.", "Finishing the icon lookup. The window will close when it completes.", "アイコン情報の取得を終了中です。完了するとウィンドウが閉じます。");
        CloseAfterPathCheck = ("종료 요청을 받았습니다. 현재 경로 확인이 끝나는 즉시 종료합니다...", "Close requested. The window will close after the current path check finishes...", "終了要求を受けました。現在のパス確認が終わり次第、終了します...");
        CloseAfterImport = ("종료와 가져오기 취소를 요청했습니다. 파일 I/O가 끝나면 종료합니다...", "Close and import cancellation requested. The window will close after file I/O finishes...", "終了とインポートの取消しを要求しました。ファイル I/O が終わると終了します...");
        CloseAfterPlanning = ("종료 요청을 받았습니다. 파일 시스템 확인이 끝나는 즉시 종료합니다...", "Close requested. The window will close after the file-system check finishes...", "終了要求を受けました。ファイルシステムの確認が終わり次第、終了します...");
        CloseAfterResult = ("종료 요청됨 · 복원 또는 결과 처리가 끝나면 종료합니다.", "Close requested; the window will close after restoration or result handling finishes.", "終了要求を受けました。復元または結果処理が終わると終了します。");
        CloseAndCancel = ("종료와 취소를 요청했습니다. 파일 처리 결과가 확인되면 종료합니다...", "Close and cancellation requested. The window will close after the file-operation result is verified...", "終了と取消しを要求しました。ファイル処理の結果を確認したら終了します...");
        ImportCancellationProgress = ("가져오기 취소를 요청했습니다. 현재 파일 I/O가 끝나면 결과를 버립니다...", "Import cancellation requested. The result will be discarded after current file I/O finishes...", "インポートの取消しを要求しました。現在のファイル I/O が終わると結果を破棄します...");
        PlanCancellationProgress = ("파일 변경 계획 취소를 요청했습니다. 현재 파일 시스템 확인 경계가 끝나면 중단합니다...", "File-change planning cancellation requested. It will stop at the next file-system check boundary...", "ファイル変更計画の取消しを要求しました。現在のファイルシステム確認の区切りで停止します...");
        ApplyCancellationProgress = ("적용 취소를 요청했습니다. 파일 처리 결과가 표시될 때까지 기다려 주세요.", "Apply cancellation requested. Wait for the file-operation result...", "適用の取消しを要求しました。ファイル処理の結果が表示されるまでお待ちください。");
        SelectingModeProgress = ("선택한 경로의 유형을 확인하고 있습니다", "Checking the selected path type", "選択したパスの種類を確認中");
        CollectingProgress = ("경로를 확인하고 있습니다", "Checking paths", "パスを確認中");
        SelectingModeShort = ("선택 유형 확인", "Checking selection type", "選択の種類を確認");
        CollectingShort = ("경로 확인", "Checking paths", "パスを確認");
        AdmissionCancellationProgress = ("경로 추가 취소를 요청했습니다. 현재 확인 경계가 끝나면 중단합니다...", "Path-add cancellation requested. It will stop at the next check boundary...", "パス追加の取消しを要求しました。現在の確認の区切りで停止します...");
        AdmissionFailedTitle = ("DarkReNamer - 추가 실패", "DarkReNamer - Add failed", "DarkReNamer - 追加に失敗");
        AddFolderStateChanged = ("확인 중 목록 또는 작업 상태가 바뀌어 폴더 추가를 시작하지 않았습니다.", "The list or operation state changed during confirmation; folder addition did not start.", "確認中に一覧または操作状態が変わったため、フォルダーの追加は始まっていません。");
        FolderAddCancelledTitle = ("DarkReNamer - 폴더 추가 취소", "DarkReNamer - Folder add cancelled", "DarkReNamer - フォルダー追加を取消し");
        FolderModeCancelled = ("폴더 추가 방식을 취소했습니다. 목록은 변경되지 않았습니다.", "Folder-add mode was cancelled. The list was not changed.", "フォルダー追加方法を取り消しました。一覧は変更されていません。");
        AdmissionWorkerCrashed = ("경로 확인 worker가 비정상 종료되었습니다. 목록은 변경되지 않았습니다.", "The path-check worker terminated unexpectedly. The list was not changed.", "パス確認ワーカーが異常終了しました。一覧は変更されていません。");
        AdmissionErrorTitle = ("DarkReNamer - 추가 오류", "DarkReNamer - Add error", "DarkReNamer - 追加エラー");
        AdmissionStaleResult = ("경로 확인 중 목록이 변경되어 결과를 적용하지 않았습니다.", "The list changed during path checking; the result was not applied.", "パスの確認中に一覧が変わったため、結果は適用していません。");
        StaleResultTitle = ("DarkReNamer - 오래된 결과", "DarkReNamer - Stale result", "DarkReNamer - 古い結果");
        FolderModeTitle = ("DarkReNamer - 폴더 추가 방식", "DarkReNamer - Folder-add mode", "DarkReNamer - フォルダー追加方法");
        FolderModeQuestion = ("선택한 폴더를 어떻게 추가할까요?", "How should the selected folder be added?", "選択したフォルダーをどの方法で追加しますか？");
        FolderModeDetail = ("목록에 추가할 범위를 선택하세요.", "Choose the scope to add to the list.", "一覧に追加する範囲を選んでください。");
        AddSelectedFolderButton = ("선택한 폴더만 추가", "Add selected folder only", "選択したフォルダーだけを追加");
        AddSubfilesButton = ("하위 파일을 모두 추가", "Add all contained files", "中のファイルをすべて追加");
        SomePathsSkippedTitle = ("DarkReNamer - 일부 경로 제외", "DarkReNamer - Some paths skipped", "DarkReNamer - 一部のパスを除外");
        PathAddCancelled = ("경로 추가를 취소했습니다. 목록은 변경되지 않았습니다.", "Path addition was cancelled. The list was not changed.", "パス追加を取り消しました。一覧は変更されていません。");
        AdmissionWorkerInternalError = ("경로 확인 worker 내부 오류가 발생했습니다. 목록은 변경되지 않았습니다.", "The path-check worker encountered an internal error. The list was not changed.", "パス確認ワーカーで内部エラーが発生しました。一覧は変更されていません。");
        AdmissionWorkerNoResult = ("경로 확인 worker가 결과를 전달하지 못했습니다. 목록은 변경되지 않았습니다.", "The path-check worker did not return a result. The list was not changed.", "パス確認ワーカーから結果が届きませんでした。一覧は変更されていません。");
        AdmissionNoResultTitle = ("DarkReNamer - 추가 결과 없음", "DarkReNamer - No add result", "DarkReNamer - 追加結果なし");
        MutationChainEmpty = ("mutation directory chain is empty", "Mutation directory chain is empty.", "変更対象のフォルダーチェーンが空です。");
        ParentMustStartLocalDrive = ("parent path must start at a local drive root", "Parent path must start at a local drive root.", "親パスはローカルドライブのルートから始まる必要があります。");
        ParentNotRooted = ("parent path is not rooted", "Parent path is not rooted.", "親パスにルートがありません。");
        ParentUnsupportedComponents = ("parent path contains unsupported components", "Parent path contains unsupported components.", "親パスに対応していない構成要素が含まれています。");
        ParentNotOrdinaryDirectory = ("parent component must be a non-reparse directory", "Parent component must be an ordinary directory, not a reparse point.", "親パスの構成要素は再解析ポイントではない通常のフォルダーである必要があります。");

        ExportMissingName = ("text export destination must have a file name", "Export destination must have a file name.", "エクスポート先にはファイル名が必要です。");
        ExportVolumeChanged = ("the save folder volume no longer matches the selected shell volume", "The save folder volume no longer matches the selected volume.", "保存先フォルダーのボリュームが選択したボリュームと一致しなくなりました。");
        ExportDirectoryChainEmpty = ("text export directory chain is empty", "Export folder chain is empty.", "エクスポート先のフォルダーチェーンが空です。");
        ExportFolderChanged = ("the save folder path no longer identifies the selected shell folder", "The save folder path no longer identifies the selected folder.", "保存先のパスが選択したフォルダーを指さなくなりました。");
        ExportInvalidName = ("text export destination has an invalid file name", "Export destination has an invalid file name.", "エクスポート先のファイル名が無効です。");
        MissingNativeCode = ("missing native error code", "Native error code is missing.", "ネイティブエラーコードがありません。");
        ExportStageUnavailable = ("could not reserve a unique text export staging file", "Could not reserve a unique export staging file.", "エクスポート用の一意な一時ファイルを確保できませんでした。");
        ExportTemporaryNameTooLong = ("text export temporary name exceeds the Windows leaf limit", "Export temporary name exceeds the Windows name limit.", "エクスポート用の一時名が Windows の名前長制限を超えています。");
        ExportTargetNotRegular = ("text export destination must be a regular, unlinked file", "Export destination must be a regular file without other hard links.", "エクスポート先は他のハードリンクがない通常のファイルである必要があります。");
        RelativeLeafInvalid = ("relative leaf is invalid", "The relative file name is invalid.", "相対ファイル名が無効です。");
        LeafTooLarge = ("leaf is too large", "The file name is too long.", "ファイル名が長すぎます。");
        RelativeOpenNoHandle = ("relative open returned no handle", "Opening the relative file returned no handle.", "相対ファイルを開いてもハンドルが返されませんでした。");
        CandidateEmptyStateLost = ("empty candidate state was lost", "The empty candidate journal state was lost.", "空の candidate ジャーナルの状態が失われました。");
        ActiveStateLost = ("active journal state was lost", "The active journal state was lost.", "active ジャーナルの状態が失われました。");
        ImportAlreadyActive = ("import already active", "An import is already active.", "インポートがすでに進行中です。");
        ImportWorkerTerminated = ("import worker terminated unexpectedly", "The import worker terminated unexpectedly.", "インポートワーカーが異常終了しました。");
        ImportWorkerNoResult = ("import worker did not return a result", "The import worker returned no result.", "インポートワーカーから結果が届きませんでした。");
        ImportTextLimit = ("import text exceeds byte limit", "Import text exceeds the byte limit.", "インポートするテキストがバイト数の上限を超えています。");
        AdmissionCancelled = ("source admission was cancelled", "Source addition was cancelled.", "元の項目の追加を取り消しました。");
        DirectoryAdmissionCancelled = ("directory admission was cancelled", "Folder addition was cancelled.", "フォルダーの追加を取り消しました。");
        WorkerPanicTitle = ("DarkReNamer - worker panic", "DarkReNamer - Worker crashed", "DarkReNamer - ワーカーが異常終了");
    }
    messages {
        journal_prepare_failed(code: u32) = ("저널을 준비하지 못했습니다. 코드 {code}", "Could not prepare the journal. Code {code}", "ジャーナルを準備できませんでした。コード {code}");
        journal_step_capacity(required: usize, maximum: usize) = ("저널의 파일 이동 단계 용량을 초과했습니다. 필요 {required}개, 최대 {maximum}개입니다.", "The journal's file-move step capacity was exceeded. Needed: {required}; maximum: {maximum}.", "ジャーナルのファイル移動ステップの容量を超えました。必要: {required}、最大: {maximum}。");
        journal_frame_capacity(required: usize, maximum: usize) = ("저널 실행 계획 용량을 초과했습니다. 필요 {required}바이트, 최대 {maximum}바이트입니다.", "The journal's execution-plan capacity was exceeded. Needed: {required} bytes; maximum: {maximum} bytes.", "ジャーナルの実行計画の容量を超えました。必要: {required} バイト、最大: {maximum} バイト。");
        restored_after_failure(reason: &str) = ("변경에 실패하여 원래 상태로 복원했습니다. {reason}", "The change failed; the original state was restored. {reason}", "変更に失敗しましたが、元の状態に戻しました。{reason}");
        recovery_required_after_failure(reason: &str) = ("상태 확인과 복구가 필요합니다. 적용이 잠겼습니다. {reason}", "A state check and recovery are required. Apply is locked. {reason}", "状態確認と復旧が必要です。適用はロックされています。{reason}");
        journal_code(code: u32) = ("저널 코드 {code}", "Journal code {code}", "ジャーナルコード {code}");
        backend_failure(context: &str, operation: &dyn std::fmt::Debug, code: u32) = ("{context} 실패: {operation:?}, Windows 코드 {code}", "{context} failed: {operation:?}, Windows code {code}", "{context}に失敗: {operation:?}、Windows コード {code}");
        export_stage_cleanup_failed(error: &dyn std::fmt::Display) = ("내보내기를 완료하지 못했고 임시 파일도 정리하지 못했습니다: {error}", "Export failed, and the temporary file could not be removed: {error}", "エクスポートに失敗し、一時ファイルも削除できませんでした: {error}");
        admission_added(appended: usize) = ("파일 {appended}개를 추가했습니다.", "Files added: {appended}.", "ファイルを {appended} 件追加しました。");
        admission_added_skipped(appended: usize, skipped: usize) = ("파일 {appended}개 추가 · {skipped}개 제외", "Files added: {appended}; skipped: {skipped}", "追加: {appended} 件・除外: {skipped} 件");
        #[allow(clippy::too_many_arguments, reason = "one complete summary checks all admission counters across three languages")]
        admission_summary(appended: usize, skipped: usize, relative: usize, metadata: usize, read_directory: usize, reparse: usize, limit: usize, repeated: usize, depth: usize, path_budget: usize) = ("{appended}개 추가, {skipped}개 제외/중단 (상대경로 {relative}, 메타데이터 {metadata}, 폴더읽기 {read_directory}, 재분석지점 {reparse}, 개수 한도 {limit}, 반복폴더 {repeated}, 깊이 {depth}, 경로 용량 {path_budget})", "Added: {appended}; skipped/stopped: {skipped} (relative path {relative}, metadata {metadata}, folder read {read_directory}, reparse point {reparse}, item limit {limit}, repeated folder {repeated}, depth {depth}, path budget {path_budget})", "追加: {appended} 件、除外/中断: {skipped} 件（相対パス {relative}、メタデータ {metadata}、フォルダー読み取り {read_directory}、再解析ポイント {reparse}、件数制限 {limit}、重複フォルダー {repeated}、深さ {depth}、パス容量 {path_budget}）");
        admission_codes(codes: &str) = (" 코드 {codes}", " Codes: {codes}", " コード: {codes}");
        blocked_journal_evidence(role: &dyn std::fmt::Debug, path: &dyn std::fmt::Display, stage: &dyn std::fmt::Debug, kind: &dyn std::fmt::Debug, os_code: &dyn std::fmt::Debug, frame: &dyn std::fmt::Debug, bytes: u64) = ("{role:?} 저널을 복구용으로 해석하지 못해 원본 핸들을 보존했습니다: {path} (단계 {stage:?}, 오류 {kind:?}, OS {os_code:?}, frame {frame:?}, {bytes} bytes). 자동 삭제하지 않았으며 새 적용은 잠겼습니다.", "Could not interpret the {role:?} journal for recovery; its original handle is retained: {path} (stage {stage:?}, error {kind:?}, OS {os_code:?}, frame {frame:?}, {bytes} bytes). It was not deleted automatically; Apply is locked.", "{role:?} ジャーナルを復旧用に解釈できず、元のハンドルを保持しました: {path}（段階 {stage:?}、エラー {kind:?}、OS {os_code:?}、frame {frame:?}、{bytes} bytes）。自動削除せず、適用をロックしました。");
        blocked_journal_unavailable(role: &dyn std::fmt::Debug, path: &dyn std::fmt::Display, stage: &dyn std::fmt::Debug, kind: &dyn std::fmt::Debug, os_code: &dyn std::fmt::Debug) = ("{role:?} 저널을 열 수 없어 원본 핸들을 보존하지 못했습니다: {path} (단계 {stage:?}, 오류 {kind:?}, OS {os_code:?}). 경로를 다시 열어 복사하지 않으며 새 적용은 잠겼습니다.", "Could not open the {role:?} journal or retain its original handle: {path} (stage {stage:?}, error {kind:?}, OS {os_code:?}). The path will not be reopened for copying; Apply is locked.", "{role:?} ジャーナルを開けず、元のハンドルを保持できませんでした: {path}（段階 {stage:?}、エラー {kind:?}、OS {os_code:?}）。コピーのためにパスを開き直さず、適用をロックしました。");
        runtime_lock_failed(error: &dyn std::fmt::Display) = ("다른 DarkReNamer 인스턴스가 실행 중이거나 runtime lock을 확보할 수 없습니다: {error}", "Another DarkReNamer instance is running, or the runtime lock could not be acquired: {error}", "別の DarkReNamer が実行中か、実行ロックを取得できません: {error}");
        active_journal_detail(path: &dyn std::fmt::Display, bytes: u64) = (" Active 저널: {path} ({bytes} bytes).", " Active journal: {path} ({bytes} bytes).", " active ジャーナル: {path}（{bytes} bytes）。");
        empty_candidate_retained(error: &dyn std::fmt::Display) = ("빈 candidate 저널을 정리하지 못해 보존했습니다: {error}. 새 적용은 잠겼습니다.", "The empty candidate journal could not be removed and is retained: {error}. Apply is locked.", "空の candidate ジャーナルを削除できず保持しました: {error}。適用をロックしました。");
        active_journal_found(path: &dyn std::fmt::Display, bytes: u64) = ("이전 실행의 active 저널을 발견했습니다: {path} ({bytes} bytes). 파일 변경 전 명시적인 복구 확인이 필요하며 새 적용은 잠겼습니다.", "An active journal from a previous run was found: {path} ({bytes} bytes). Explicit recovery confirmation is required before changing files; Apply is locked.", "前回の実行の active ジャーナルが見つかりました: {path}（{bytes} bytes）。ファイル変更前に明示的な復旧確認が必要です。適用をロックしました。");
        staged_journal_found(path: &dyn std::fmt::Display) = ("활성화 전 저널을 보존했습니다: {path}. 파일 변경은 시작되지 않았으며 새 적용은 잠겼습니다.", "A pre-activation journal is retained: {path}. No file changes began; Apply is locked.", "有効化前のジャーナルを保持しました: {path}。ファイル変更は始まっておらず、適用をロックしました。");
        staged_journal_also_retained(path: &dyn std::fmt::Display) = (" 활성화 전 저널도 보존했습니다: {path}. 새 적용은 잠겼습니다.", " A pre-activation journal is also retained: {path}. Apply is locked.", " 有効化前のジャーナルも保持しました: {path}。適用をロックしました。");
        journal_details(path: &dyn std::fmt::Display, bytes: u64, records: usize) = ("저널: {path}\n크기: {bytes} bytes\n레코드: {records}개", "Journal: {path}\nSize: {bytes} bytes\nRecords: {records}", "ジャーナル: {path}\nサイズ: {bytes} bytes\nレコード: {records} 件");
        recovery_dialog_failed(error: &dyn std::fmt::Display) = ("안전 확인 대화상자를 열지 못해 복구를 시작하지 않았습니다: {error}", "The confirmation dialog could not be opened; recovery did not start: {error}", "安全確認ダイアログを開けず、復旧は開始されませんでした: {error}");
        journal_cleanup_failed(error: &dyn std::fmt::Display) = (" 저널 삭제 실패: {error}", " Journal removal failed: {error}", " ジャーナルの削除に失敗: {error}");
        recovery_blocked(reason: &dyn std::fmt::Debug) = ("현재 파일 상태와 저널을 대조한 결과 복구가 차단되었습니다: {reason:?}. active 저널을 보존하고 새 적용을 잠급니다.", "Recovery was blocked after comparing file state with the journal: {reason:?}. The active journal is retained and Apply is locked.", "現在のファイル状態とジャーナルの照合により復旧がブロックされました: {reason:?}。active ジャーナルを保持し、適用をロックします。");
        recovery_incomplete(reason: &dyn std::fmt::Debug) = ("복구를 완료하지 못했습니다: {reason:?}. active 저널을 보존하고 새 적용을 잠급니다.", "Recovery could not be completed: {reason:?}. The active journal is retained and Apply is locked.", "復旧を完了できませんでした: {reason:?}。active ジャーナルを保持し、適用をロックします。");
        export_skipped_no_handle(role: &dyn std::fmt::Debug) = ("건너뜀: {role:?} 저널은 retained handle을 확보하지 못했습니다.", "Skipped: no retained handle was acquired for the {role:?} journal.", "スキップ: {role:?} ジャーナルの保持ハンドルを取得できませんでした。");
        export_failed(path: &dyn std::fmt::Display, error: &dyn std::fmt::Display) = ("실패: {path} ({error})", "Failed: {path} ({error})", "失敗: {path}（{error}）");
        discard_dialog_failed(error: &dyn std::fmt::Display) = ("안전 확인 대화상자를 열지 못해 폐기를 취소했습니다: {error}", "The confirmation dialog could not be opened; discard was cancelled: {error}", "安全確認ダイアログを開けず、破棄を取り消しました: {error}");
        discard_journal_failed(error: &dyn std::fmt::Display) = ("활성화 전 저널을 폐기하지 못했습니다: {error}", "The pre-activation journal could not be discarded: {error}", "有効化前のジャーナルを破棄できませんでした: {error}");
        recovery_active_detail(path: &dyn std::fmt::Display, bytes: u64, records: usize) = ("Active: {path} ({bytes} bytes, {records} records)", "Active: {path} ({bytes} bytes, {records} records)", "Active: {path}（{bytes} bytes、{records} 件のレコード）");
        recovery_candidate_detail(path: &dyn std::fmt::Display, bytes: u64, kind: &str) = ("Candidate: {path} ({bytes} bytes, {kind})", "Candidate: {path} ({bytes} bytes, {kind})", "Candidate: {path}（{bytes} bytes、{kind}）");
        column_writer_start_failed(error: &dyn std::fmt::Display) = ("열 표시 설정 writer를 시작하지 못했습니다. 현재 작업에는 영향이 없습니다: {error}", "The column settings writer could not start. Current work is unaffected: {error}", "列表示設定の保存ワーカーを開始できませんでした。現在の作業には影響しません: {error}");
        appearance_writer_start_failed(error: &dyn std::fmt::Display) = ("모양 설정 writer를 시작하지 못했습니다. 현재 작업에는 영향이 없습니다: {error}", "The appearance settings writer could not start. Current work is unaffected: {error}", "外観設定の保存ワーカーを開始できませんでした。現在の作業には影響しません: {error}");
        column_writer_timer_failed(error: &dyn std::fmt::Display) = ("열 표시 설정 완료 감시 timer를 시작하지 못했습니다: {error}", "Could not start the column settings completion timer: {error}", "列表示設定の完了監視タイマーを開始できませんでした: {error}");
        apply_confirmation_content(scope: &str, primary: &str, examples: &str) = ("{scope}\n\n{primary}\n\n{examples}\n\n아직 파일을 변경하지 않았습니다. 취소하면 미리보기로 돌아갑니다.", "{scope}\n\n{primary}\n\n{examples}\n\nNo files have been changed yet. Cancel returns to the preview.", "{scope}\n\n{primary}\n\n{examples}\n\nファイルはまだ変更されていません。キャンセルするとプレビューに戻ります。");
        apply_dialog_failed(error: &dyn std::fmt::Display) = ("안전 확인 대화상자를 열지 못해 적용을 취소했습니다: {error}", "The confirmation dialog could not be opened; Apply was cancelled: {error}", "安全確認ダイアログを開けず、適用を取り消しました: {error}");
        apply_completed_rows(count: usize) = ("{count}개 변경 완료 · 목록에 실제 결과를 반영했습니다.", "Changes completed: {count}; the list now shows the actual result.", "変更完了: {count} 件。実際の結果を一覧に反映しました。");
        planner_timer_failed(error: &dyn std::fmt::Display) = ("planning worker 완료 감시 timer를 시작하지 못했습니다: {error}", "Could not start the planning worker completion timer: {error}", "計画ワーカーの完了監視タイマーを開始できませんでした: {error}");
        planner_start_failed(error: &dyn std::fmt::Display) = ("planning worker를 시작하지 못했습니다: {error}", "Could not start the planning worker: {error}", "計画ワーカーを開始できませんでした: {error}");
        journal_root_transfer_failed(error: &dyn std::fmt::Display) = ("저널 루트 권한을 worker로 전달하지 못했습니다. {error}", "Could not transfer journal-root authority to the worker. {error}", "ジャーナルルートの権限をワーカーに渡せませんでした。{error}");
        apply_worker_timer_failed(error: &dyn std::fmt::Display) = ("worker 완료 감시 timer를 시작하지 못했습니다: {error}", "Could not start the worker completion timer: {error}", "ワーカーの完了監視タイマーを開始できませんでした: {error}");
        apply_worker_start_failed(error: &dyn std::fmt::Display) = ("적용 worker를 시작하지 못했습니다: {error}", "Could not start the Apply worker: {error}", "適用ワーカーを開始できませんでした: {error}");
        apply_cancel_requested(completed: usize, total: usize) = ("취소 요청됨 · 처리 결과를 기다려 주세요 ({completed}/{total} 단계)", "Cancellation requested; wait for the result (step {completed}/{total})", "取消しを要求しました。結果をお待ちください（{completed}/{total} ステップ）");
        apply_ready(total: usize) = ("실행 준비 완료: {total} 단계", "Ready to execute: {total} steps", "実行準備完了: {total} ステップ");
        apply_forward(completed: usize, total: usize) = ("파일 변경 중: {completed}/{total} 단계", "Changing files: step {completed}/{total}", "ファイル変更中: {completed}/{total} ステップ");
        apply_rollback(completed: usize, total: usize) = ("원래 상태로 복원 중: {completed}/{total} 단계 · 복원은 중단할 수 없습니다", "Restoring the original state: step {completed}/{total}; restoration cannot be cancelled", "元の状態に復元中: {completed}/{total} ステップ。復元は中断できません");
        active_journal_create_failed(error: &dyn std::fmt::Display) = ("활성 저널을 만들지 못했습니다. {error}", "Could not create the active journal. {error}", "active ジャーナルを作成できませんでした。{error}");
        close_message_failed(error: &dyn std::fmt::Display) = ("종료 준비 메시지를 예약하지 못했습니다: {error}", "Could not queue the close-preparation message: {error}", "終了準備メッセージを予約できませんでした: {error}");
        admission_timer_failed(error: &dyn std::fmt::Display) = ("admission worker 완료 감시 timer를 시작하지 못했습니다: {error}", "Could not start the admission worker completion timer: {error}", "追加ワーカーの完了監視タイマーを開始できませんでした: {error}");
        admission_worker_start_failed(error: &dyn std::fmt::Display) = ("admission worker를 시작하지 못했습니다: {error}", "Could not start the admission worker: {error}", "追加ワーカーを開始できませんでした: {error}");
        admission_progress_cancellable(phase: &str) = ("{phase}... (취소 가능)", "{phase}... (can cancel)", "{phase}...（取消し可能）");
        admission_progress_inspected(phase: &str, inspected: usize) = ("{phase}: {inspected}개 검사 시작됨 (취소 가능)", "{phase}: started checking {inspected} items (can cancel)", "{phase}: {inspected} 件の確認を開始（取消し可能）");
        admission_cancellation_inspected(phase: &str, inspected: usize) = ("경로 추가 취소를 요청했습니다. {phase} {inspected}개 검사 시작 후 현재 확인 경계가 끝나면 중단합니다...", "Path-add cancellation requested. After {inspected} {phase} checks started, it will stop at the next check boundary...", "パス追加の取消しを要求しました。{phase} {inspected} 件の確認を開始した後、現在の確認の区切りで停止します...");
        folder_mode_dialog_failed(error: &dyn std::fmt::Display) = ("폴더 추가 방식 대화상자를 열지 못해 추가를 취소했습니다: {error}", "The folder-add mode dialog could not be opened; addition was cancelled: {error}", "フォルダー追加方法のダイアログを開けず、追加を取り消しました: {error}");
        selected_directory(path: &str) = ("선택한 폴더: {path}", "Selected folder: {path}", "選択したフォルダー: {path}");
        admission_result_unchanged(error: &str) = ("{error} 기존 목록은 그대로 유지됩니다.", "{error} The existing list is unchanged.", "{error} 既存の一覧は変更されていません。");
        admission_result_not_applied(error: &str) = ("{error}\n\n경로 확인 결과를 반영하지 않았으며 기존 목록은 그대로 유지됩니다.", "{error}\n\nThe path-check result was not applied; the existing list is unchanged.", "{error}\n\nパス確認の結果は反映せず、既存の一覧は変更されていません。");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::i18n::{Language, with_language};

    #[test]
    fn recovery_guidance_preserves_no_mutation_and_locked_apply_in_each_language() {
        for (language, no_mutation, lock) in [
            (
                Language::Korean,
                "파일 변경은 시작되지",
                "적용은 잠겼습니다",
            ),
            (
                Language::English,
                "No file changes began",
                "Apply is locked",
            ),
            (
                Language::Japanese,
                "ファイル変更は始まっておらず",
                "適用をロック",
            ),
        ] {
            with_language(language, || {
                let text = staged_journal_found(&r"C:\Users\Test\journal\candidate.drj");
                assert!(text.contains(no_mutation));
                assert!(text.contains(lock));
                assert!(text.contains("candidate.drj"));
            });
        }
    }

    #[test]
    fn add_summary_counts_and_codes_survive_translation() {
        for language in [Language::Korean, Language::English, Language::Japanese] {
            with_language(language, || {
                let text = admission_summary(3, 2, 1, 0, 0, 0, 1, 0, 0, 0);
                assert!(text.contains('3'));
                assert!(text.contains('2'));
                assert!(text.contains('1'));
                let coded = admission_codes("Open:32");
                assert!(coded.contains("Open:32"));
            });
        }
    }
}
