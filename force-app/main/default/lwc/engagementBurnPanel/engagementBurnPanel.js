import { LightningElement, api, wire } from 'lwc';
import getEngagementBurn from '@salesforce/apex/EngagementBurnController.getEngagementBurn';

const COLUMNS = [
    { label: 'Resource', fieldName: 'resource', wrapText: true, sortable: true },
    { label: 'Model', fieldName: 'model', fixedWidth: 90, sortable: true },
    { label: 'Forecast', fieldName: 'forecast', type: 'number', sortable: true, cellAttributes: { alignment: 'right' } },
    { label: 'Worked', fieldName: 'worked', type: 'number', sortable: true, cellAttributes: { alignment: 'right' } },
    { label: 'Rem.', fieldName: 'remaining', type: 'number', sortable: true, cellAttributes: { alignment: 'right' } },
    { label: '% Cons.', fieldName: 'pctConsumed', type: 'number', sortable: true,
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: '% Elap.', fieldName: 'pctComplete', type: 'number', sortable: true,
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Run-rate 6wk', fieldName: 'runRate6wk', type: 'number', sortable: true,
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: '% Bkd', fieldName: 'pctBooked', type: 'number', sortable: true, cellAttributes: { alignment: 'right' } },
    { label: 'Proj. undel. (hr)', fieldName: 'projUndelivered', type: 'number', sortable: true, cellAttributes: { alignment: 'right' } },
    { label: 'Rev. at risk', fieldName: 'revenueAtRisk', type: 'currency', sortable: true,
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    // Status carries a colored dot via cellAttributes.class -> see getter that decorates rows
    { label: 'Status', fieldName: 'status', sortable: true, cellAttributes: { class: { fieldName: 'statusClass' } } }
];

export default class EngagementBurnPanel extends LightningElement {
    @api recordId;
    columns = COLUMNS;
    data;
    summary;
    error;

    // Default: highest revenue at risk first
    sortedBy = 'revenueAtRisk';
    sortDirection = 'desc';

    @wire(getEngagementBurn, { engagementId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this.summary = data;
            const mapped = (data.assignments || []).map((a) => ({
                ...a,
                statusClass: this.statusClass(a.status)
            }));
            this.data = sortData(mapped, this.sortedBy, this.sortDirection);
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortDirection = event.detail.sortDirection;
        this.data = sortData(this.data, this.sortedBy, this.sortDirection);
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

/** Stable client-side sort; nulls always sort last regardless of direction. */
function sortData(rows, field, direction) {
    const factor = direction === 'asc' ? 1 : -1;
    const cloned = [...rows];
    cloned.sort((a, b) => {
        let x = a[field];
        let y = b[field];
        if (x == null && y == null) return 0;
        if (x == null) return 1;
        if (y == null) return -1;
        if (typeof x === 'string') { x = x.toLowerCase(); y = String(y).toLowerCase(); }
        if (x > y) return factor;
        if (x < y) return -factor;
        return 0;
    });
    return cloned;
}
