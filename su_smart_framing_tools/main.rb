# frozen_string_literal: true

# su_smart_framing_tools/main.rb
#
# Smart Framing Tools – UI 登録ハブ
#
# SketchupExtension が有効化された際に require されるメインファイル。
# 依存ファイルの読み込みと、メニュー・ツールバー・コンテキストメニューの登録を行う。
#
# ■ 登録内容
#   - Plugins メニュー > Smart Framing Tools サブメニュー（5 コマンド）
#   - UI::Toolbar "Smart Framing Tools"（5 コマンド、アイコンは icons/ に置けば自動適用）
#   - 右クリックコンテキストメニュー > Smart Framing Tools サブメニュー（5 コマンド）

module SuSmartFramingTools
  # 依存ファイルを require（Ruby の require キャッシュにより重複ロードなし）
  dir = File.dirname(__FILE__)
  require File.join(dir, 'core',  'geometry_helper')
  require File.join(dir, 'tools', 'trim_tool')
  require File.join(dir, 'tools', 'split_tool')
  require File.join(dir, 'tools', 'align_tool')
  require File.join(dir, 'tools', 'corner_tool')
  require File.join(dir, 'tools', 'extend_tool')

  unless file_loaded?(__FILE__)
    # ----------------------------------------------------------------
    # ツール定義テーブル
    # label: メニュー/ツールバーに表示する名前
    # icon:  icons/ 以下のファイルベース名（拡張子なし）
    # klass: 起動するツールクラス
    # ----------------------------------------------------------------
    ICON_DIR = File.join(File.dirname(__FILE__), 'icons').freeze

    TOOL_DEFS = [
      { label: 'Trim（トリム）',       icon: 'trim',   klass: TrimTool   },
      { label: 'Split（スプリット）',   icon: 'split',  klass: SplitTool  },
      { label: 'Align（アライン）',     icon: 'align',  klass: AlignTool  },
      { label: 'Corner（コーナー）',    icon: 'corner', klass: CornerTool },
      { label: 'Extend（延伸）',        icon: 'extend', klass: ExtendTool },
    ].freeze

    # ----------------------------------------------------------------
    # Plugins メニュー登録
    # ----------------------------------------------------------------
    plugins_menu = UI.menu('Plugins')
    submenu      = plugins_menu.add_submenu('Smart Framing Tools')

    TOOL_DEFS.each do |td|
      submenu.add_item(td[:label]) { Sketchup.active_model.select_tool(td[:klass].new) }
    end

    # ----------------------------------------------------------------
    # ツールバー生成
    # UI::Command を TOOL_DEFS から生成し toolbar に追加する。
    # アイコンファイルが icons/<name>.svg に存在する場合のみ設定
    # （ファイルが無い状態でもエラーにならないフォールバック付き）。
    # toolbar.restore により前回の表示状態（位置・表示/非表示）を自動復元する。
    # ----------------------------------------------------------------
    toolbar = UI::Toolbar.new('Smart Framing Tools')

    TOOL_DEFS.each do |td|
      cmd = UI::Command.new(td[:label]) { Sketchup.active_model.select_tool(td[:klass].new) }
      cmd.tooltip          = td[:label]
      cmd.status_bar_text  = td[:label]

      # .svg → .pdf のフォールバック順でアイコンを探す
      icon_path = %w[svg pdf png].map { |ext|
        File.join(ICON_DIR, "#{td[:icon]}.#{ext}")
      }.find { |p| File.exist?(p) }

      if icon_path
        cmd.small_icon = icon_path
        cmd.large_icon = icon_path
      end

      toolbar.add_item(cmd)
    end

    toolbar.restore

    # ----------------------------------------------------------------
    # 右クリックコンテキストメニュー登録
    # "Smart Framing Tools" サブメニューとして全5ツールを追加する。
    # ----------------------------------------------------------------
    UI.add_context_menu_handler do |menu|
      sub = menu.add_submenu('Smart Framing Tools')
      TOOL_DEFS.each do |td|
        sub.add_item(td[:label]) { Sketchup.active_model.select_tool(td[:klass].new) }
      end
    end

    file_loaded(__FILE__)
  end
end
