#  vim: set fileencoding=utf-8 filetype=ruby ts=2 : 

module SwfRuby
  class ReplaceTarget
    attr_accessor :offset
  end

  class Jpeg2ReplaceTarget < ReplaceTarget
    attr_accessor :jpeg

    def initialize(offset, jpeg)
      @offset = offset
      @jpeg = jpeg
    end
  end

  class Lossless2ReplaceTarget < ReplaceTarget
    attr_accessor :image

    def initialize(offset, image)
      @offset = offset
      @image = SwfRuby::Swf::BitsLossless2.new(image)
    end
  end

  class SpriteReplaceTarget < ReplaceTarget
    attr_accessor :swf
    attr_accessor :frame_count
    attr_accessor :define_tags
    attr_accessor :control_tags
    attr_accessor :idmap
    attr_accessor :target_define_tags_string
    attr_accessor :target_control_tags_string
    attr_reader :target_swf_dumper

    def initialize(offset, swf)
      @offset = offset
      @swf = swf
      @target_swf_dumper = SwfDumper.new.dump(@swf)
      @frame_count = @target_swf_dumper.header.frame_count
      @define_tags = @target_swf_dumper.tags.select { |t| t.define_tag? }
      @control_tags = @target_swf_dumper.tags - @define_tags
      @idmap = { 65535 => 65535 }
    end

    def self.build_list_by_instance_var_names(swf_dumper, var_name_to_swf)
      from_character_id = (swf_dumper.tags.collect { |t| t.define_tag? ? t.character_id : nil }).compact.max + 1
      repl_targets = []
      var_name_to_swf.each do |var_name, swf|
        repl_target, from_character_id = SwfRuby::SpriteReplaceTarget.build_by_instance_var_name(swf_dumper, var_name, swf, from_character_id)
        repl_targets << repl_target
      end
      repl_targets
    end

    # 指定したインスタンス変数名に対するSpriteReplaceTargetを生成する
    def self.build_by_instance_var_name(swf_dumper, var_name, swf, from_character_id = nil)
      from_character_id ||= (swf_dumper.tags.collect { |t| t.define_tag? ? t.character_id : nil }).compact.max + 1
      refer_character_id = nil
      sprite_indices = {}
      swf_dumper.tags.each_with_index do |t,i|
        if t.character_id
          sprite_indices[t.character_id] = i
        end
        if Swf::TAG_TYPE[t.code] == "DefineSprite"
          sd = SwfRuby::SpriteDumper.new
          sd.dump(t)
          sd.tags.each do |t2|
            if var_name == t2.refer_character_inst_name
              refer_character_id = t2.refer_character_id
              break
            end
          end
        else
          if var_name == t.refer_character_inst_name
            refer_character_id = t.refer_character_id
          end
        end
        break if refer_character_id
      end
      raise ReplaceTargetError unless refer_character_id
      offset = swf_dumper.tags_addresses[sprite_indices[refer_character_id]]
      srt = SpriteReplaceTarget.new(offset, swf)
      srt.target_define_tags_string, from_character_id = srt.build_define_tags_string(from_character_id)
      srt.target_control_tags_string = srt.build_control_tags_string
      [srt, from_character_id]
    end

    # 置換するSWFからCharacterIdを付け替えながらDefineタグを抽出する.
    # 対象のSWFにBitmapIDの参照が含まれる場合、これも合わせて付け替える.
    # 同時に、CharacterIdの対応付けマップを作成する.
    def build_define_tags_string(from_character_id)
      str = ""
      @define_tags.each do |t|
        if t.character_id
          from_character_id += 1
          @idmap[t.character_id] = from_character_id
          str << t.rawdata_with_define_character_id(@idmap, @idmap[t.character_id])
        end
      end
      [str, from_character_id+1]
    end

    # DefineSpriteに埋め込むためのControl tagsのみを抽出する.
    # 参照先のcharacter_idを変更する必要がある場合は付け替える.
    def build_control_tags_string
      str = ""
      valid_control_tag_codes = [0, 1, 4, 5, 12, 18, 19, 26, 28, 43, 45, 70, 72]
      @control_tags.each do |t|
        next unless valid_control_tag_codes.include? t.code
        if @idmap[t.refer_character_id]
          str << t.rawdata_with_refer_character_id(@idmap[t.refer_character_id])
        else
          str << t.rawdata
        end
      end
      str
    end
  end

  class AsVarReplaceTarget < ReplaceTarget
    attr_accessor :do_action_offset
    attr_accessor :parent_sprite_offset
    attr_reader :str

    def initialize(action_push_offset, do_action_offset, str, parent_sprite_offset = nil)
      @offset = action_push_offset
      @do_action_offset = do_action_offset
      @str = str
      @parent_sprite_offset = parent_sprite_offset
    end

    def str=(str)
      @str << str
    end

    # 指定したAS変数名に対するAsVarReplaceTargetのリストを生成する
    def self.build_by_var_name(swf_dumper, var_name)
      as_var_replace_targets = []
      swf_dumper.tags.each_with_index do |t, i|
        if t.code == 39
          # DefineSprite
          sd = SpriteDumper.new
          sd.dump(t)
          sd.tags.each_with_index do |u, j|
            if u.code == 12
              # DoAction in DefineSprite
              as_var_replace_targets += AsVarReplaceTarget.generate_as_var_replace_target_by_do_action(var_name, swf_dumper, j, sd, swf_dumper.tags_addresses[i])
            end
          end
        end
        if t.code == 12
          # DoAction
          as_var_replace_targets += AsVarReplaceTarget.generate_as_var_replace_target_by_do_action(var_name, swf_dumper, i)
        end
      end
      as_var_replace_targets
    end

    # 指定したインデックス(SWFまたはSpriteの先頭からカウント)にあるDoAction以下を走査し、
    # 指定したAS変数名の代入部分を発見し、AsVarReplaceTargetのリストを生成する.
    def self.generate_as_var_replace_target_by_do_action(var_name, swf_dumper, do_action_index, sprite_dumper = nil, parent_sprite_offset = nil)
      as_var_replace_targets = []
      action_records = []
      do_action_offset = 0

      dad = DoActionDumper.new
      if sprite_dumper
        do_action_offset = parent_sprite_offset + sprite_dumper.tags_addresses[do_action_index]
        dad.dump(swf_dumper.swf[do_action_offset, sprite_dumper.tags[do_action_index].length])
      else
        do_action_offset = swf_dumper.tags_addresses[do_action_index]
        dad.dump(swf_dumper.swf[do_action_offset, swf_dumper.tags[do_action_index].length])
      end
      dad.actions.each_with_index do |ar, i|
        # ActionPush, SetVariableの並びを検出したら変数名をチェック.
        action_records.shift if action_records.length > 2
        action_records << ar
        if ar.code == 29 && action_records[-2] && action_records[-2].code == 150
          # 直前のActionPushが複数データをpushしているかどうかチェック.
          ars = action_records[-2].data.split("\0").reject { |e| e.empty? }
          if ars[0] == var_name
            if ars[1]
              # 複数データpushなので\0\0 separatedなデータをつくる
              as_var_replace_targets << AsVarReplaceTarget.new(
                do_action_offset + dad.actions_addresses[i] - action_records[-2].length,
                do_action_offset,
                "#{var_name}\0\0",
                parent_sprite_offset
              )
            end
          elsif action_records[-3] && action_records[-3].code == 150 && action_records[-3].data.delete("\0") == var_name
            # 連続ActionPush
            as_var_replace_targets << AsVarReplaceTarget.new(
            do_action_offset + dad.actions_addresses[i] - action_records[-2].length,
              do_action_offset,
              "",
              parent_sprite_offset
            )
          end
        end
      end
      as_var_replace_targets
    end
  end

  # 置換対象指定エラー.
  class ReplaceTargetError < StandardError; end
end
