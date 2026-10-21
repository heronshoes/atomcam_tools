<template>
  <ElRow>
    <ElCol :offset="titleOffset" :span="9 - titleOffset">
      <h4 v-if="$te(i18n + '.title')" v-t="i18n+'.title'" />
      <h4 v-else />
    </ElCol>
    <ElCol :span="15 - titleOffset">
      <div class="well preset">
        <ElTimePicker class="time-picker" v-model="innerValue.time" :placeholder="$t('schedule.time')" value-format="HH:mm" format="HH:mm" @change="Changed" />
        <ElInput class="preset-commands" v-model="innerValue.commands" :placeholder="$t('scheduleSettings.preset.placeholder')" @input="Changed" />
        <ElButton class="preset-button" type="text" size="small" circle icon="el-icon-minus" @click="$emit('remove', $event)" />
        <ElButton class="preset-button" type="text" size="small" circle icon="el-icon-plus" @click="$emit('add', $event)" />
      </div>
    </ElCol>
  </ElRow>
</template>

<script>
  import { TimePicker, Input } from 'element-ui';
  import 'element-ui/lib/theme-chalk/time-picker.css';
  import 'element-ui/lib/theme-chalk/input.css';

  // one entry of PRESET_SCHEDULE: { time: 'HH:MM', commands: '<cmd>|<cmd>...' }
  export default {
    components: {
      ElTimePicker: TimePicker,
      ElInput: Input,
    },
    props: {
      titleOffset: {
        type: Number,
        default: 1,
      },
      i18n: {
        type: String,
        default: '',
      },
      value: {
        type: Object,
        required: true,
      },
    },
    data() {
      return {
        innerValue: { ...this.value },
      };
    },
    watch: {
      value(v) {
        this.innerValue = { ...v };
      },
    },
    methods: {
      Changed() {
        this.$emit('input', this.innerValue);
      },
    },
  };
</script>

<style scoped>
  .preset {
    display: inline-flex;
    align-items: center;
    width: 95%;
    padding: 5px;
  }
  .time-picker {
    width: 110px;
    flex-shrink: 0;
  }
  .preset-commands {
    margin: 0px 5px 0px 10px;
  }
  .preset-button {
    padding: 0;
    margin-left: 5px;
  }
</style>
