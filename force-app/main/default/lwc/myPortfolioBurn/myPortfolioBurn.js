import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getMyPortfolio from '@salesforce/apex/EngagementBurnController.getMyPortfolio';

const COLUMNS = [
    { label: 'Engagement', fieldName: 'name', wrapText: true,
      cellAttributes: { class: { fieldName: 'statusClass' } } },
    { label: 'Model', fieldName: 'model', fixedWidth: 90 },
    { label: '% Cons.', fieldName: 'pctConsumed', type: 'number',
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: '% Elap.', fieldName: 'pctComplete', type: 'number',
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Worked', fieldName: 'worked', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Forecast', fieldName: 'forecast', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Run-rate', fieldName: 'runRate', type: 'number',
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Proj. undel. (hr)', fieldName: 'projUndeliveredHrs', type: 'number', cellAttributes: { alignment: 'right' } },
    { label: 'Rev. at risk', fieldName: 'revenueAtRisk', type: 'currency',
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    { label: 'Status', fieldName: 'status', cellAttributes: { class: { fieldName: 'statusClass' } } },
    { type: 'button-icon', fixedWidth: 40,
      typeAttributes: { iconName: 'utility:forward', title: 'Open', name: 'open', variant: 'bare' } }
];

export default class MyPortfolioBurn extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    rows;
    error;

    @wire(getMyPortfolio)
    wired({ data, error }) {
        if (data) {
            this.rows = data.map((e) => ({ ...e, statusClass: this.statusClass(e.status) }));
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    statusClass(status) {
        switch (status) {
            case 'On track': return 'slds-text-color_success';
            case 'At risk':  return 'slds-text-color_error';
            default:         return 'slds-text-color_warning';
        }
    }

    handleRowAction(event) {
        const id = event.detail.row.engagementId;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: id, objectApiName: 'KimbleOne__DeliveryGroup__c', actionName: 'view' }
        });
    }

    get hasRows() { return this.rows && this.rows.length > 0; }
}
