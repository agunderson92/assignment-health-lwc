import { LightningElement, api, wire } from 'lwc';
import getEngagementBurn from '@salesforce/apex/EngagementBurnController.getEngagementBurn';

const COLUMNS = [
    { label: 'Resource', fieldName: 'resource', wrapText: true },
    { label: 'Model', fieldName: 'model', fixedWidth: 90 },
    { label: 'Forecast', fieldName: 'forecast', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Worked', fieldName: 'worked', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Rem.', fieldName: 'remaining', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: '% Cons.', fieldName: 'pctConsumed', type: 'number',
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: '% Elap.', fieldName: 'pctComplete', type: 'number',
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Run-rate 6wk', fieldName: 'runRate6wk', type: 'number',
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: '% Bkd', fieldName: 'pctBooked', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Proj. undel. (hr)', fieldName: 'projUndelivered', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Rev. at risk', fieldName: 'revenueAtRisk', type: 'currency',
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    // Status carries a colored dot via cellAttributes.class -> see getter that decorates rows
    { label: 'Status', fieldName: 'status', cellAttributes: { class: { fieldName: 'statusClass' } } }
];

export default class EngagementBurnPanel extends LightningElement {
    @api recordId;
    columns = COLUMNS;
    data;
    summary;
    error;

    @wire(getEngagementBurn, { engagementId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this.summary = data;
            this.data = (data.assignments || []).map((a) => ({
                ...a,
                statusClass: this.statusClass(a.status)
            }));
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    statusClass(status) {
        switch (status) {
            case 'On track': return 'slds-text-color_success';
            case 'At risk':  return 'slds-text-color_error';
            default:         return 'slds-text-color_warning'; // Watch / Verify / Monitor / As-needed / Paused
        }
    }

    get headline() {
        if (!this.summary) return '';
        const s = this.summary;
        const rev = s.revenueAtRisk ? ` · ~$${Number(s.revenueAtRisk).toLocaleString()} T&M at risk` : '';
        return `${s.status} · ${s.pctConsumed ?? '–'}% consumed vs ${s.pctComplete ?? '–'}% elapsed · run-rate ${s.runRate ?? '–'} hr/wk${rev}`;
    }
    get hasData() { return this.data && this.data.length > 0; }
}
