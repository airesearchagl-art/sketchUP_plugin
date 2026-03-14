# frozen_string_literal: true

# su_smart_framing_tools/tools/align_tool.rb
#
# AlignTool – ソリッド端部を基準平面に揃えるツール（未実装・スケルトン）
#
# TODO: 基準となる平面（フェイス）を選択し、対象ソリッドの端面をその平面に
#       ぴったり揃える（延伸またはトリムを自動判定して実行）。

module SuSmartFramingTools
  class AlignTool
    include GeometryHelper

    TOOL_NAME = 'Align（アライン）'.freeze

    def activate
      puts "[#{TOOL_NAME}] activate: ツール起動（未実装）"
      Sketchup.status_text = "【アライン】現在準備中です。"
    end

    def deactivate(view)
      view.invalidate
    end

    def resume(view)
      Sketchup.status_text = "【アライン】現在準備中です。"
      view.invalidate
    end

    def draw(_view); end

    def onMouseMove(_flags, _x, _y, _view); end

    def onLButtonDown(_flags, _x, _y, _view)
      UI.messagebox("#{TOOL_NAME} は現在準備中です。", MB_OK)
    end

    def onKeyDown(key, _repeat, _flags, _view)
      Sketchup.active_model.select_tool(nil) if key == 27  # ESC
    end
  end
end
