import DatePicker from "discourse/components/date-picker";

export default DatePicker.extend({
  layoutName: "components/date-picker",
  defaultDate: null,

  _opts() {
    if (this.defaultDate) {
      return {
        defaultDate: moment(this.defaultDate).toDate(),
        setDefaultDate: true,
        maxDate: new Date()
      };
    } else {
      return {
        defaultDate: new Date(),
        maxDate: new Date()
      };
    }
  }
});
